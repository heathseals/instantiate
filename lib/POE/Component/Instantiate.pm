################################################################################
# This is a non-blocking (forking w/Poe::Wheel::Run) wrapper around the various
# service provider libraries (EC2::Actions, Linode::Actions, and
# VMware::ESX::Actions) The theory is that the Provider libraries should provide
# A common interface for the various Actions, and this module will create task
# lists and run through the tasks sequentially, but without blocking any other
# POE events that are going on at the time...
################################################################################
package POE::Component::Instantiate;
use POE;
use POE qw( Wheel::Run );
use JSON;
$|=1;

# Things we "know how to do"
# the 'sp:*' items go here (service provider)
use EC2::Actions;
use LinodeAPI::Actions;
use VMware::ESX::Actions;

# the 'wc:*' items come from here (websages configure)
use WebSages::Configure;

sub new {
    my $class = shift;
    my $self = bless { }, $class;
    my $cnstr = shift if @_;
    $self->{'action'} = $cnstr->{'action'}."::Action" if $cnstr->{'action'};
    $self->{'credentials'} = $cnstr->{'connection'} if $cnstr->{'connection'};
    POE::Session->create(
                          options => { debug => 0, trace => 0},
                          object_states => [
                                             $self => {
                                                         _start           => "_poe_start",
                                                         add_clipboard    => "add_clipboard",
                                                         shutdown         => "shutdown",
                                                         destroy          => "destroy",
                                                         clean_keys       => "clean_keys",
                                                         deploy           => "deploy",
                                                         get_macaddr      => "get_macaddr",
                                                         ldap_pxe         =>  "ldap_pxe",
                                                         dhcplinks        => "dhcplinks",
                                                         poweron          => "poweron",
                                                         ping_until_up    => "ping_until_up",
                                                         ldap_nopxe       => "ldap_nopxe",
                                                         ping_until_down  => "ping_until_down",
                                                         post_config      => "post_config",
                                                         inspect_config   => "inspect_config",
                                                         cleanup          => "cleanup",
                                                         esx_redeploy     => "esx_redeploy",
                                                         do_nonblock      => "do_nonblock",
                                                         got_child_stdout => "on_child_stdout",
                                                         got_child_stderr => "on_child_stderr",
                                                         got_child_close  => "on_child_close",
                                                         got_child_signal => "on_child_signal",
                                                         _stop            => "_poe_stop",
                                                      },
                                           ],
                        );
    return $self;
}

sub service_provider{
    my $self = shift;
    my $type = shift||$self->{'action'};
    my $creds = shift||$self->{'credentials'};
    if($type == 'VMware::ESX'){
        return VMware::ESX::Actions->new($creds);
    }
    if($type == 'Linode'){
        return Linode::Actions->new($creds);
    }
    if($type == 'EC2'){
        return EC2::Actions->new($creds);
    }
}

sub _poe_start {
    my ($self, $kernel, $heap, $sender, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    $self->{'sp'} = $self->service_provider();
    $self->{'wc'} =  WebSages::Configure->new({
                                                'fqdn'    => $instance_fqdn,
                                                'ldap'    => {
                                                               'bind_dn'  => $ENV{'LDAP_BINDDN'},
                                                               'password' => $ENV{'LDAP_PASSWORD'}
                                                             },
                                                'gitosis' => "$ENV{'GITOSIS_HOME'}",
                                             };
    $_[KERNEL]->alias_set("$_[OBJECT]"); # set the object as an alias so it may be 'posted' to
}

sub _poe_stop {
    my ($self, $kernel, $heap, $sender, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    $_[KERNEL]->alias_remove("$_[OBJECT]");
}

################################################################################
# Master Tasks
################################################################################
sub add_clipboard{
    my ($self, $kernel, $heap, $sender, $cb, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    $heap->{'clipboard'} = $cb;
}
################################################################################
# There are subtle differences in how each type is deployed, here's where we
# make those distinctions. What the service provider api does is only a 
# small part of the actual work that gets done...
#
# These functions are the *remote* function name in the sp: or wc: module
# they will be passed the clipboard when called. The module being called 
# should inspect the clipboard for what it needs before doing work.
################################################################################
sub redeploy {
    my ($self, $kernel, $heap, $sender, $cb, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    if($type == 'VMware::ESX'){
        $heap->{'actions'} = [ 
                               "wc:disable_monitoring",        # supress monitoring for the host
                               "sp:shutdown",                  # power off the node
                               "sp:destroy",                   # delete the node from disk
                               "wc:clean_keys",                # remove exitsing trusted keys (cfengine ppkeys)
                               "sp:deploy",                    # deploy the new host
                               "sp:get_macaddr",               # get the MAC address from the API
                               "wc:ldap_pxe",                  # updated the MAC address in ou=DHCP in LDAP, set do boot pxe
                               "wc:dhcplinks",                 # call dhcplinks.cgi to generate tftpboot symlinks
                               "sp:poweron",                   # power on the vm (it should PXE by default)
                               "wc:ping_until_up",             # ping the host until you recieve icmp (should then be installing)
                               "wc:ldap_nopxe",                # set the ou=DHCP to boot locally
                               "wc:dhcplinks",                 # call dhcplinks.cgi again to point it to localboot 
                               "wc:ping_until_down",           # ping it until it goes down (the reboot at the end of install)
                               "wc:ping_until_up",             # ping it until it comes back online
                               "wc:wait_for_ssh",              # wait until ssh is available 
                               "wc:post_config",               # log in and do any post configuration
                               "wc:inspect_config",            # poke around and make sure everything looks good
                               "wc:cleanup"                    # remove any temp files 
                               "wc:enable_monitoring",         # re-enable monitoring for the host
                             ];
    }
    if($type == 'Linode'){
        $heap->{'actions'} = [ 
                               "wc:disable_monitoring",        # supress monitoring for the host
                               "sp:shutdown",                  # power off the node
                               "sp:destroy",                   # delete the node from disk
                               "wc:clean_keys",                # remove existing trusted keys
                               "sp:deploy",                    # deploy new node
                               "sp:get_pub_ip",                # query the API for the remote public IP
                               "wc:stow_ip",                   # save the public IP in LDAP
                               "wc:ssh_keyscan",               # get the new ssh fingerprints
                               "wc:update_dns",                # update dns sshfp / a records
                               "wc:wait_for_ssh",              # wait until ssh is available 
                               "wc:mount_opt",                 # log in and mount /opt, set /etc/fstab
                               "sp:set_kernel_pv_grub",        # set the kernel to boot pv_grub on the next boot
                               "wc:make_remote_dsa_keypair",   # generate a ssh-keypair for root
                               "wc:ldap_host_record_update",   # update ou=Hosts with the new information
                               "wc:save_ldap_secret",          # save the ldap secret if provided
                               "wc:update_gitosis_key",        # update the root's key in gitosis (for app deployments)
                               "wc:prime_hosts",               # download prime and run it (installs JeCM and puppet)
                               "wc:wait_for_reboot",           # puppet will install a new kernel and reboot
                               "wc:ping_until_up",             # wait for the box to come back online
                               "wc:wait_for_ssh",              # wait until ssh is available 
                               "wc:inspect_puppet_logs",       # follow the puppet logs until they error out or complete
                               "wc:enable_monitoring",         # re-enable monitoring for the host
                             ];
    }
    if($type == 'EC2'){
        $heap->{'actions'} = [ 
                               "wc:disable_monitoring",        # supress monitoring for the host
                               "sp:shutdown",                  # power off the node
                               "sp:destroy",                   # terminate the instance
                               "wc:clean_keys",                # remove existing trusted keys
                               "sp:deploy",                    # deploy a new slice
                               "sp:get_pub_ip",                # get the remote public IP for the slice
                               "wc:stow_ip",                   # save the public IP in LDAP
                               "wc:ssh_keyscan",               # scan the host for it's new ssh keys
                               "wc:update_dns",                # update dns sshfp / a records
                               "sp:wait_for_ec2_console",      # wait until the node comes up
                               "wc:set_root_password",         # log in and set the root password
                               "wc:make_remote_dsa_keypair",   # create root's ssh keypair
                               "wc:ldap_host_record_update",   # update ou=Hosts with the new information
                               "wc:save_ldap_secret",          # save the LDAP secret
                               "wc:update_gitosis_key",        # update gitosis with the new root ssh-pubkey
                               "wc:prime_hosts",               # download prime and run it (installs JeCM and puppet)
                               "wc:inspect_puppet_logs",       # follow the puppet logs until they error out or complete
                               "wc:enable_monitoring",         # re-enable monitoring for the host
                             ];
    }
    # grab the first job and pass the clipboard and remaining jobs to the first job
    $kernel->yield('next_item'), if($heap->{'actions'}->[0]);
}
    
################################################################################
# Worker Tasks :
#
# any output to STDOUT will be interpreted as YAML and will replace the contents
# of $heap->{'clipboard'} (a metaphor for the clipboard being passed back)
################################################################################
sub next_item {
    my ($self, $kernel, $heap, $sender, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my $task = shift(@{ $heap->{'actions'} });
    if($task=~m/([^:]*):(.*)/){
        print "$1->$2\n";
        $kernel->yield('do_nonblock',
                       sub { 
                               $self->{$1}->$2($heap->{'clipboard'});
                           }
                      );
    }else{
        # if it's not in a module then assume it's ours.
        print "$task\n";
        $kernel->yield('do_nonblock',
                   sub { 
                           $self->$task($heap->{'clipboard'});
                       }
                  );
    }
}

################################################################################
# Forker Tasks
# 
# This is just a textbook case of POE::Wheel::Run that will also re-write the
# $heap->{'clipboard'} with the YAML the child prints to STDOUT (if valid)
################################################################################

sub do_nonblock{
    my ($self, $kernel, $heap, $sender, @args) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my $child = POE::Wheel::Run->new(
        Program      => $args[0],
        StdoutEvent  => "got_child_stdout",
        StderrEvent  => "got_child_stderr",
        CloseEvent   => "got_child_close",
    );
    $kernel->sig_child($child->PID, "got_child_signal");
    # Wheel events include the wheel's ID.
    $heap->{children_by_wid}{$child->ID} = $child;
    # Signal events include the process ID.
    $heap->{children_by_pid}{$child->PID} = $child;
    print( "Child pid ", $child->PID, " started as wheel ", $child->ID, ".\n");
}

    # Wheel event, including the wheel's ID.
sub on_child_stdout {
    my ($self, $kernel, $heap, $sender, $stdout_line, $wheel_id) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my ($stdout_line, $wheel_id) = @_[ARG0, ARG1];
    my $child = $heap->{children_by_wid}{$wheel_id};
    $heap->{'child_output'}.="$stdout_line\n";
    #print "pid ", $child->PID, " STDOUT: $stdout_line\n";
}

# Wheel event, including the wheel's ID.
sub on_child_stderr {
    my ($self, $kernel, $heap, $sender, $stderr_line, $wheel_id) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my $child = $eap->{children_by_wid}{$wheel_id};
    print "pid ", $child->PID, " STDERR: $stderr_line\n" unless($stderr_line=~m/SSL_connect/);
}

# Wheel event, including the wheel's ID.
sub on_child_close {
    my ($self, $kernel, $heap, $sender, $wheel_id) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    my $child = delete $heap->{children_by_wid}{$wheel_id};

    # May have been reaped by on_child_signal().
    unless (defined $child) {
      print "wid $wheel_id closed all pipes.\n";
      return;
    }
    print "pid ", $child->PID, " closed all pipes.\n";
    delete $heap->{children_by_pid}{$child->PID};
    # only proceed if we've closed
    if(defined($heap->{'child_output'})){
        # FIXME this should be done on a private set of filehandles, not on STDOUT
        my $replacement_clipboard;
        eval { $replacement_clipboard = YAML::Load("$heap->{'child_output'}\n"); };
        if( $ $@){
            $heap->{'clipboard'} = $replacement_clipboard;
        }else{
            # stop all remaining tasks if something printed out to STDOUT that wasn't YAML
            print STDERR "Non-YAML STDOUT found. Aborting work thread.\n";
            print STDERR "$heap->{'child_output'}\n";
            $heap->{'actions'} = undef;
        }
        $heap->{'child_output'} = undef;
    }
    # move to the next item
    $kernel->yield('next_item') if($heap->{'actions'}->[0]);
  }

sub on_child_signal {
    my ($self, $kernel, $heap, $sender, $wheel_id, $pid, $status) = @_[OBJECT, KERNEL, HEAP, SENDER, ARG0 .. $#_];
    print "pid $pid exited with status $status.\n";
    exit if($status ne 0);
    my $child = delete $heap->{children_by_pid}{$status};
    # May have been reaped by on_child_close().
    return unless defined $child;
    delete $heap->{children_by_wid}{$child->ID};
}
1;
