#
# Copyright 2019 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package apps::genesys::snmp::mode::connectedclients;

use base qw(centreon::plugins::templates::counter);

use strict;
use warnings;
use centreon::plugins::statefile;
use centreon::plugins::templates::catalog_functions qw(catalog_status_threshold catalog_status_calc);
use apps::genesys::snmp::common qw(get_oidtable reload_cache check_controlrow);

my %oids_gsInfoTable = (
    'gsClientsExistNum'  => '.1.3.6.1.4.1.1729.100.1.4.1.1',
);

sub prefix_server_output {
    my ($self, %options) = @_;

    return "Application '" . $options{instance_value}->{display} . "' ";
}

sub custom_clients_calc {
    my ($self, %options) = @_;

    foreach (keys %{$options{new_datas}}) {
        if (/^\Q$self->{instance}\E_(.*)/) {
            $self->{result_values}->{$1} = $options{new_datas}->{$_};
        }
    }

    return 0;
}

sub custom_clients_threshold_check {
    my ($self, %options) = @_;

    my $value = $self->{result_values}->{'client'};
    my $ctrlstatus = $self->{result_values}->{'ctrlstatus'};
    my $refreshstatus = $self->{result_values}->{'refreshstatus'};

    if ( $ctrlstatus =~ /active/ ) {
        if ( $refreshstatus =~ /dataReady/ ) {
            my $warn = defined($self->{threshold_warn}) ? $self->{threshold_warn} : 'warning-' . $self->{thlabel};
            my $crit = defined($self->{threshold_crit}) ? $self->{threshold_crit} : 'critical-' . $self->{thlabel};

            return $self->{perfdata}->threshold_check(value => $value, threshold => [ { label => $crit, 'exit_litteral' => 'critical' },
                                                                                      { label => $warn, 'exit_litteral' => 'warning' }]);
        }
        return 'unknown';
    } else {
        return 'unknown';
    }
}

sub custom_clients_output {
    my ($self, %options) = @_;

    my $msg;
    my $value = $self->{result_values}->{'client'};
    my $ctrlstatus = $self->{result_values}->{'ctrlstatus'};
    my $refreshstatus = $self->{result_values}->{'refreshstatus'};

    if ( $ctrlstatus =~ /active/ && $refreshstatus =~ /dataReady/ ) {
        $msg = 'has ' . $value . ' client' . ($value < 2 ? '' : 's') . ' currently connected.';
    } else {
        $msg = 'data is not ready (' . $ctrlstatus . (defined($refreshstatus) ? ', ' . $refreshstatus : '') . ')...';
    }

    return $msg;
}

sub custom_clients_perfdata {
    my ($self, %options) = @_;

    if ( $self->{result_values}->{'ctrlstatus'} =~ /active/ && $self->{result_values}->{'refreshstatus'} =~ /dataReady/ ) {
        my $warn = defined($self->{threshold_warn}) ? $self->{threshold_warn} : 'warning-' . $self->{thlabel};
        my $crit = defined($self->{threshold_crit}) ? $self->{threshold_crit} : 'critical-' . $self->{thlabel};

        $self->{output}->perfdata_add(
            label => $self->{label},
            instances => $self->{result_values}->{'display'},
            nlabel => $self->{nlabel},
            value => int($self->{result_values}->{'client'}),
            warning => $self->{perfdata}->get_perfdata_for_output(label => $warn, cast_int => 1),
            critical => $self->{perfdata}->get_perfdata_for_output(label => $crit, cast_int => 1),
            min => 0,
        );
    }
}

sub set_counters {
    my ($self, %options) = @_;

    $self->{maps_counters_type} = [
        { name => 'gservers', type => 1, cb_prefix_output => 'prefix_server_output', message_multiple => 'All applications are ok' },
    ];

    $self->{maps_counters}->{gservers} = [
        { label => 'clients', nlabel => 'gserver.client', set => {
                manual_keys => 1,
                closure_custom_calc => $self->can('custom_clients_calc'),
                closure_custom_threshold_check => $self->can('custom_clients_threshold_check'),
                closure_custom_output => $self->can('custom_clients_output'),
                closure_custom_perfdata => $self->can('custom_clients_perfdata'),
            }
        },
    ];
}

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(package => __PACKAGE__, %options);
    bless $self, $class;

    $options{options}->add_options(arguments => {
        'application:s'         => { name => 'application' },
        'name'                  => { name => 'use_name' },
        'reload-cache-time:s'   => { name => 'reload_cache_time', default => 180 },
        'show-cache'            => { name => 'show_cache' },
    });

    $self->{gserver_dbid_selected} = undef;
    $self->{statefile_cache} = centreon::plugins::statefile->new(%options);

    return $self;
}

sub check_options {
    my ($self, %options) = @_;
    $self->SUPER::check_options(%options);
    $self->{statefile_cache}->check_options(%options);
}

sub manage_selection {
    my ($self, %options) = @_;

    $self->get_selection(snmp => $options{snmp});

    my $oids_gServerTable = $self->get_oidtable(name => 'gServerTable');

    my $gserver_control = $self->check_controlrow(
        snmp => $options{snmp},
        instances => [$self->{gserver_dbid_selected}],
        table => 'gsInfoTable',
        create_missing => 1
    );
    my %mappings = (
        gServerName => { oid => $oids_gServerTable->{gServerName}->{oid} },
        gsClientsExistNum => { oid => $oids_gsInfoTable{gsClientsExistNum} },
    );

    $options{snmp}->load(
        oids => [$oids_gServerTable->{gServerName}->{oid}, $oids_gsInfoTable{gsClientsExistNum}],
        instances => [$self->{gserver_dbid_selected}],
        nothing_quit => 1
    );
    my $snmp_result = $options{snmp}->get_leef();

    $self->{gservers} = {};
    my $instance = $self->{gserver_dbid_selected};
    my $result = $options{snmp}->map_instance(mapping => \%mappings, results => $snmp_result, instance => $instance);

    $self->{gservers}->{$result->{gServerName}} = {
        ctrlstatus => $gserver_control->{$instance}->{rowstatus},
        refreshstatus => $gserver_control->{$instance}->{refreshstatus},
        display => $result->{gServerName},
        client => $result->{gsClientsExistNum},
    };
}

sub get_selection {
    my ($self, %options) = @_;

    # init cache file
    my $has_cache_file = $self->{statefile_cache}->read(statefile => 'cache_snmpstandard_' . $options{snmp}->get_hostname()  . '_' . $options{snmp}->get_port() . '_gservers');
    if (defined($self->{option_results}->{show_cache})) {
        $self->{output}->add_option_msg(long_msg => $self->{statefile_cache}->get_string_content());
        $self->{output}->option_exit();
    }

    my $timestamp_cache = $self->{statefile_cache}->get(name => 'last_timestamp');
    if ($has_cache_file == 0 || !defined($timestamp_cache) || ((time() - $timestamp_cache) > (($self->{option_results}->{reload_cache_time}) * 60))) {
            $self->reload_cache(snmp => $options{snmp});
            $self->{statefile_cache}->read();
    }

    my $all_ids = $self->{statefile_cache}->get(name => 'all_ids');

    if (defined($self->{option_results}->{application})) {
        if (!defined($self->{option_results}->{use_name})) {
            my $name = $self->{statefile_cache}->get(name => "gServerName_" . $self->{option_results}->{application});
            $self->{gserver_dbid_selected} = $self->{option_results}->{application} if (defined($name));
        } else {
            foreach my $i (@{$all_ids}) {
                my $gserver_name = $self->{statefile_cache}->get(name => 'gServerName' . '_' . $i);
                $self->{gserver_dbid_selected} = $i if ($gserver_name eq $self->{option_results}->{application});
            }
        }
    }

    if (!defined($self->{gserver_dbid_selected})) {
        $self->{output}->add_option_msg(short_msg => "No application found. Can be: filters, cache file.");
        $self->{output}->option_exit();
    }
}

1;

__END__

=head1 MODE

Check client connections.

=over 8

=item B<--warning-clients>

Threshold warning for total client connections.

=item B<--critical-clients>

Threshold critical for total client connections.

=item B<--application>

Set the application (number expected) ex: 1, 2,... (empty means 'check all applications').

=item B<--name>

Allows to use application name with option --application instead of application dbid.

=item B<--reload-cache-time>

Time in minutes before reloading cache file (default: 180).

=item B<--show-cache>

Display cache application data.

=back

=cut
