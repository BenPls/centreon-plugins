################################################################################
# Copyright 2005-2014 MERETHIS
# Centreon is developped by : Julien Mathis and Romain Le Merlus under
# GPL Licence 2.0.
# 
# This program is free software; you can redistribute it and/or modify it under 
# the terms of the GNU General Public License as published by the Free Software 
# Foundation ; either version 2 of the License.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A 
# PARTICULAR PURPOSE. See the GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along with 
# this program; if not, see <http://www.gnu.org/licenses>.
# 
# Linking this program statically or dynamically with other modules is making a 
# combined work based on this program. Thus, the terms and conditions of the GNU 
# General Public License cover the whole combination.
# 
# As a special exception, the copyright holders of this program give MERETHIS 
# permission to link this program with independent modules to produce an executable, 
# regardless of the license terms of these independent modules, and to copy and 
# distribute the resulting executable under terms of MERETHIS choice, provided that 
# MERETHIS also meet, for each linked independent module, the terms  and conditions 
# of the license of that module. An independent module is a module which is not 
# derived from this program. If you modify this program, you may extend this 
# exception to your version of the program, but you are not obliged to do so. If you
# do not wish to do so, delete this exception statement from your version.
# 
# For more information : contact@centreon.com
# Authors : Quentin Garnier <qgarnier@merethis.com>
#
####################################################################################

package apps::vmware::connector::mode::nethost;

use base qw(centreon::plugins::mode);

use strict;
use warnings;
use apps::vmware::connector::lib::common;
use ZMQ::LibZMQ3;
use ZMQ::Constants qw(:all);
use UUID;

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(package => __PACKAGE__, %options);
    bless $self, $class;
    
    $self->{version} = '1.0';
    $options{options}->add_options(arguments =>
                                { 
                                  "connector-hostname:s"    => { name => 'connector_hostname' },
                                  "connector-port:s"        => { name => 'connector_port', default => 5700 },
                                  "container:s"             => { name => 'container', default => 'default' },
                                  "esx-hostname:s"          => { name => 'esx_hostname' },
                                  "nic-name:s"              => { name => 'nic_name' },
                                  "filter"                  => { name => 'filter' },
                                  "filter_nic"              => { name => 'filter_nic' },
                                  "disconnect-status:s"     => { name => 'disconnect_status', default => 'unknown' },
                                  "warning-in:s"            => { name => 'warning_in', },
                                  "critical-in:s"           => { name => 'critical_in', },
                                  "warning-out:s"           => { name => 'warning_out', },
                                  "critical-out:s"          => { name => 'critical_out', },
                                  "link-down-status:s"      => { name => 'link_down_status', },
                                  "timeout:s"               => { name => 'timeout', default => 50 },
                                });
    $self->{json_send} = {};
    return $self;
}

sub check_options {
    my ($self, %options) = @_;
    $self->SUPER::init(%options);

    if (!defined($self->{option_results}->{connector_hostname}) ||
        $self->{option_results}->{connector_hostname} eq '') {
        $self->{output}->add_option_msg(short_msg => "Please set option --connector-hostname.");
        $self->{output}->option_exit();
    }
    if (defined($self->{option_results}->{timeout}) && $self->{option_results}->{timeout} =~ /^\d+$/ &&
        $self->{option_results}->{timeout} > 0) {
        $self->{timeout} = $self->{option_results}->{timeout};
    } else {
        $self->{timeout} = 50;
    }
    
    foreach my $label (('warning_in', 'critical_in', 'warning_out', 'critical_out')) {
        if (($self->{perfdata}->threshold_validate(label => $label, value => $self->{option_results}->{$label})) == 0) {
            my ($label_opt) = $label;
            $label_opt =~ tr/_/-/;
            $self->{output}->add_option_msg(short_msg => "Wrong " . $label_opt . " threshold '" . $self->{option_results}->{$label} . "'.");
            $self->{output}->option_exit();
        }
    }
    if ($self->{output}->is_litteral_status(status => $self->{option_results}->{disconnect_status}) == 0) {
        $self->{output}->add_option_msg(short_msg => "Wrong disconnect-status status option '" . $self->{option_results}->{disconnect_status} . "'.");
        $self->{output}->option_exit();
    }
    if ($self->{output}->is_litteral_status(status => $self->{option_results}->{link_down_status}) == 0) {
        $self->{output}->add_option_msg(short_msg => "Wrong link down status option '" . $self->{option_results}->{link_down_status} . "'.");
        $self->{output}->option_exit();
    }
}

sub build_request {
    my ($self, %options) = @_;
    
    $self->{json_send}->{identity} = 'client-' . unpack('H*', $options{uuid});
    $self->{json_send}->{command} = 'nethost';
    foreach (keys %{$self->{option_results}}) {
        $self->{json_send}->{$_} = $self->{option_results}->{$_};
    }
}

sub run {
    my ($self, %options) = @_;

    my $uuid;
    my $context = zmq_init();
    $self->{requester} = zmq_socket($context, ZMQ_DEALER);
    if (!defined($self->{requester})) {
        $self->{output}->add_option_msg(short_msg => "Cannot create socket: $!");
        $self->{output}->option_exit();
    }
    
    my $flag = ZMQ_NOBLOCK | ZMQ_SNDMORE;
    UUID::generate($uuid);
    zmq_setsockopt($self->{requester}, ZMQ_IDENTITY, "client-" . $uuid);
    zmq_setsockopt($self->{requester}, ZMQ_LINGER, 0); # we discard
    zmq_connect($self->{requester}, 'tcp://' . $self->{option_results}->{connector_hostname} . ':' . $self->{option_results}->{connector_port});
    
    $self->build_request(uuid => $uuid);
    
    zmq_sendmsg($self->{requester}, "REQCLIENT " . JSON->new->utf8->encode($self->{json_send}), ZMQ_NOBLOCK);
    
    my @poll = (
        {
            socket  => $self->{requester},
            events  => ZMQ_POLLIN,
            callback => sub {
               my $response = zmq_recvmsg($self->{requester});
               zmq_close($self->{requester});
               apps::vmware::connector::lib::common::connector_response($self, response => $response);
               $self->{output}->display();
               $self->{output}->exit();
            },
        },
    );
    
    zmq_poll(\@poll, $self->{timeout} * 1000);    
    zmq_close($self->{requester});
    
    $self->{output}->output_add(severity => 'UNKNOWN',
                                short_msg => sprintf("Cannot get response (timeout received)"));
    $self->{output}->display();
    $self->{output}->exit();
}

1;

__END__

=head1 MODE

Check ESX net usage.

=over 8

=item B<--connector-hostname>

Connector hostname (required).

=item B<--connector-port>

Connector port (default: 5700).

=item B<--container>

Container to use (it depends of the connector configuration).

=item B<--esx-hostname>

ESX hostname to check.
If not set, we check all ESX.

=item B<--filter>

ESX hostname is a regexp.

=item B<--nic-name>

ESX nic to check.
If not set, we check all nics.

=item B<--filter-nic>

Nic name is a regexp.

=item B<--disconnect-status>

Status if ESX host disconnected (default: 'unknown').

=item B<--link-down-status>

Status if some links are down (default: 'critical').

=item B<--timeout>

Set global execution timeout (Default: 50)

=item B<--warning-in>

Threshold warning traffic in (percent).

=item B<--critical-in>

Threshold critical traffic in (percent).

=item B<--warning-out>

Threshold warning traffic out (percent).

=item B<--critical-out>

Threshold critical traffic out (percent).

=back

=cut
