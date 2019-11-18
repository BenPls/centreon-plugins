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

package apps::genesys::snmp::mode::serverstatus;

use base qw(centreon::plugins::templates::counter);

use strict;
use warnings;
use centreon::plugins::statefile;
use centreon::plugins::templates::catalog_functions qw(catalog_status_threshold catalog_status_calc);

my %map_gServerStatus = (
    1 => 'unknown',
    2 => 'stopped',
    3 => 'pending',
    4 => 'running',
    5 => 'initializing',
    6 => 'serviceUnavailable',
    7 => 'suspending',
    8 => 'suspended'
);

my %oids_gServerTable = (
    'gServerName'    => '.1.3.6.1.4.1.1729.100.1.2.1.2',
    'gServerStatus'  => '.1.3.6.1.4.1.1729.100.1.2.1.3',
    'gServerType'     => '.1.3.6.1.4.1.1729.100.1.2.1.4',
);

my %mappings = (
	gServerName => { oid => $oids_gServerTable{gServerName} },
	gServerType => { oid => $oids_gServerTable{gServerType} },
	gServerStatus => { oid => $oids_gServerTable{gServerStatus}, map => \%map_gServerStatus },
);

sub set_counters {
    my ($self, %options) = @_;

    $self->{maps_counters_type} = [
        { name => 'gservers', type => 1, cb_prefix_output => 'prefix_server_output', message_multiple => 'All applications are ok' },
    ];

    $self->{maps_counters}->{gservers} = [
        { label => 'status', nlabel => 'gserver.status', threshold => 0, set => {
                key_values => [ { name => 'app_status' }, { name => 'display' } ],
                closure_custom_calc => \&catalog_status_calc,
                closure_custom_output => $self->can('custom_status_output'),
                closure_custom_perfdata => sub { return 0; },
                closure_custom_threshold_check => \&catalog_status_threshold,
            }
        },
    ];
}

sub custom_status_output {
    my ($self, %options) = @_;

    my $msg = 'status is ' . $self->{result_values}->{app_status};
    return $msg;
}

sub prefix_server_output {
    my ($self, %options) = @_;

    return "Application '" . $options{instance_value}->{display} . "' ";
}

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(package => __PACKAGE__, %options);
    bless $self, $class;
    
    $options{options}->add_options(arguments => {
        'warning:s'             => { name => 'warning', },
        'critical:s'            => { name => 'critical', },
        'app-name:s'            => { name => 'app_name' },
        'regexp-name'           => { name => 'regexp_name' },
        'exclude-name:s@'       => { name => 'exclude_name' },
        'app-type:s'            => { name => 'app_type' },
        'regexp-type'           => { name => 'regexp_type' },
        'exclude-type:s@'       => { name => 'exclude_type' },
        'unknown-status:s'      => { name => 'unknown_status', default => '%{app_status} =~ /unknown/i' },
        'warning-status:s'      => { name => 'warning_status', default => '%{app_status} =~ /serviceUnavailable/i || %{app_status} =~ /initializing/i || %{app_status} =~ /pending/i' },
        'critical-status:s'     => { name => 'critical_status', default => '%{app_status} =~ /stopped/i || %{app_status} =~ /suspending/i || %{app_status} =~ /suspended/i' },
        'reload-cache-time:s'   => { name => 'reload_cache_time', default => 180 },
        'show-cache'            => { name => 'show_cache' },
    });
   
    $self->{gserver_dbid_selected} = [];
    $self->{statefile_cache} = centreon::plugins::statefile->new(%options);

    return $self;
}

sub check_options {
    my ($self, %options) = @_;
    $self->SUPER::check_options(%options);
    $self->{statefile_cache}->check_options(%options);

	$self->change_macros(macros => ['unknown_status', 'warning_status', 'critical_status']);

	$self->{exclude_name} = [];
	foreach my $val (@{$self->{option_results}->{exclude_name}}) {
		next if (!defined($val) || $val eq '');
		push @{$self->{exclude_name}}, $val; 
	}
	$self->{exclude_type} = ['Resource Access Point', 'Database Access Point'];
	foreach my $val (@{$self->{option_results}->{exclude_type}}) {
		next if (!defined($val) || $val eq '');
		push @{$self->{exclude_type}}, $val; 
	}
}

sub manage_selection {
    my ($self, %options) = @_;

    $self->get_selection(snmp => $options{snmp});
    
    $options{snmp}->load(
        oids => [$oids_gServerTable{gServerName}, $oids_gServerTable{gServerType}, $oids_gServerTable{gServerStatus}], 
        instances => $self->{gserver_dbid_selected},
        nothing_quit => 1
    );
    my $snmp_result = $options{snmp}->get_leef();

    $self->{gservers} = {};
    foreach (sort @{$self->{gserver_dbid_selected}}) {
        my $instance = $_;
        my $result = $options{snmp}->map_instance(mapping => \%mappings, results => $snmp_result, instance => $instance);

    	$self->{gservers}->{$result->{gServerName}} = {
            display => $result->{gServerName}, 
			app_status => $result->{gServerStatus},
		};
	}
}

sub reload_cache {
    my ($self, %options) = @_;
    my $data = {};

    $data->{last_timestamp} = time();
    $data->{all_ids} = [];
    
    my $request = [ 
    	{ oid => $oids_gServerTable{gServerName} },
    	{ oid => $oids_gServerTable{gServerType} }
    ];
    
    my $result = $options{snmp}->get_multiple_table(oids => $request);

    foreach ((['name', 'gServerName'], ['type', 'gServerType'])) {
		foreach my $key ($options{snmp}->oid_lex_sort(keys %{$result->{ $oids_gServerTable{$$_[1]} }})) {
	        next if ($key !~ /\.([0-9]+)$/);        
	        my $server_index = $1;

            if ($$_[1] =~ /gServerName/i) {
		        push @{$data->{all_ids}}, $server_index;
	        }
	        
	        $data->{$$_[1] . '_' . $server_index} = $self->{output}->to_utf8($result->{ $oids_gServerTable{$$_[1]} }->{$key});
	    }
	}

    if (scalar(@{$data->{all_ids}}) <= 0) {
        $self->{output}->add_option_msg(short_msg => "Can't construct cache...");
        $self->{output}->option_exit();
    }

    $self->{statefile_cache}->write(data => $data);
}

sub get_selection {
    my ($self, %options) = @_;

    # init cache file
    my $has_cache_file = $self->{statefile_cache}->read(statefile => 'cache_snmpstandard_' . $options{snmp}->get_hostname()  . '_' . $options{snmp}->get_port() . '_' . $self->{mode});
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
	
	foreach my $i (@{$all_ids}) {
		my $filters = { name => 1, type => 1 };
		my $gserver = { name => $self->{statefile_cache}->get(name => 'gServerName' . '_' . $i), type => $self->{statefile_cache}->get(name => 'gServerType' . '_' . $i) };

		foreach my $filter (keys %$filters) {
			if (defined($self->{option_results}->{'app_' . $filter}) && $self->{option_results}->{'app_' . $filter} ne '') {
				if (defined($self->{option_results}->{'regexp_' . $filter})) {
					$filters->{$filter} = $gserver->{$filter} =~ /$self->{option_results}->{'app_' . $filter}/;
				} else {
					$filters->{$filter} = $gserver->{$filter} eq $self->{option_results}->{'app_' . $filter};
				}
			}
			foreach my $exclude_filter (@{$self->{'exclude_' . $filter}}) {
				$filters->{$filter} = $filters->{$filter} && !($gserver->{$filter} =~ /$exclude_filter/);
			}
		}
		if ($filters->{name} && $filters->{type}) {
			push @{$self->{gserver_dbid_selected}}, $i;
		} else {
			$self->{output}->output_add(long_msg => "Skipping application '" . $gserver->{name} . "': no matching filter.", debug => 1);
		}
	}
    
    if (scalar(@{$self->{gserver_dbid_selected}}) <= 0) {
        $self->{output}->add_option_msg(short_msg => "No application found. Can be: filters, cache file.");
        $self->{output}->option_exit();
    }
}

1;

__END__

=head1 MODE

Check application status.

=over 8

=item B<--app-name>

Filter application name.

=item B<--regexp-name>

Allows to use regexp to filter application 
name (with option --app-name).

=item B<--exclude-name>

Exclude some applications (Example: --exclude-name=xxx --exclude-name=yyyy)

=item B<--app-type>

Filter application type.

=item B<--regexp-type>

Allows to use regexp to filter application 
type (with option --app-type).

=item B<--unknown-status>

Set warning threshold for status (Default: '%{app_status} =~ /unknown/i').
Can used special variables like: %{app_status}

=item B<--warning-status>

Set warning threshold for status (Default: '%{app_status} =~ /serviceUnavailable/i || %{app_status} =~ /initializing/i || %{app_status} =~ /pending/i').
Can used special variables like: %{app_status}

=item B<--critical-status>

Set critical threshold for status (Default: '%{app_status} =~ /stopped/i || %{app_status} =~ /suspending/i || %{app_status} =~ /suspended/i').
Can used special variables like: %{app_status}

=item B<--reload-cache-time>

Time in minutes before reloading cache file (default: 180).

=item B<--show-cache>

Display cache storage data.

=back

=cut
