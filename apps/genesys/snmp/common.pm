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

package apps::genesys::snmp::common;

use strict;
use warnings;
use Exporter;

our @ISA = qw(Exporter);
our @EXPORT_OK = qw($map_gsCtrlTableID get_oidtable reload_cache);

my $map_gsCtrlTableID = {
    1 => 'gsLogTable',
    2 => 'gsInfoTable',
    3 => 'gsClientTable',
    4 => 'gsPollingTable',
    5 => 'tsInfoTable',
    6 => 'tsCallTable',
    7 => 'tsDtaTable',
    8 => 'tsLinkTable',
    9 => 'tsCallFilterTable',
    10 => 'tsCallInfoTable',
    11 => 'tsLinkStatsTable'
};

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

my %map_gsCtrlRowStatus = (
    1 => 'active',
    2 => 'notInService',
    3 => 'notReady',
    4 => 'createAndGo',
    5 => 'createAndWait',
    6 => 'destroy'
);

my %map_gsCtrlRefreshStatus = (
    1 => 'dataNotReady',
    2 => 'dataRefreshInProgress',
    3 => 'dataReady',
    4 => 'mgmtIsNotAvailable',
    5 => 'dataRefreshFailed'
);

my %goids = (
    gServerTable => {
        gServerName    => { oid => '.1.3.6.1.4.1.1729.100.1.2.1.2' },
        gServerStatus  => { oid => '.1.3.6.1.4.1.1729.100.1.2.1.3', map => \%map_gServerStatus },
        gServerType    => { oid => '.1.3.6.1.4.1.1729.100.1.2.1.4' },
    },
    gServerControlTable => {
        gsCtrlRefreshStatus  => { oid => '.1.3.6.1.4.1.1729.100.1.3.1.3', map => \%map_gsCtrlRefreshStatus },
        gsCtrlRowStatus      => { oid => '.1.3.6.1.4.1.1729.100.1.3.1.6', map => \%map_gsCtrlRowStatus },
    },
);

sub get_oidtable {
    my ($self, %options) = @_;

    return $goids{$options{name}};
}

sub reload_cache {
    my ($self, %options) = @_;
    my $data = {};

    $data->{last_timestamp} = time();
    $data->{all_ids} = [];

    my $oids_gServerTable = $self->get_oidtable( name => 'gServerTable' );

    my $request = [
        { oid => $oids_gServerTable->{gServerName}->{oid} },
        { oid => $oids_gServerTable->{gServerType}->{oid} }
    ];

    my $result = $options{snmp}->get_multiple_table(oids => $request);

    foreach ((['name', 'gServerName'], ['type', 'gServerType'])) {
        foreach my $key ($options{snmp}->oid_lex_sort(keys %{$result->{ $oids_gServerTable->{$$_[1]}->{oid} }})) {
            next if ($key !~ /\.([0-9]+)$/);
            my $server_index = $1;

            if ($$_[1] =~ /gServerName/i) {
                push @{$data->{all_ids}}, $server_index;
            }

            $data->{$$_[1] . '_' . $server_index} = $self->{output}->to_utf8($result->{ $oids_gServerTable->{$$_[1]}->{oid} }->{$key});
        }
    }

    if (scalar(@{$data->{all_ids}}) <= 0) {
        $self->{output}->add_option_msg(short_msg => "Can't construct cache...");
        $self->{output}->option_exit();
    }

    $self->{statefile_cache}->write(data => $data);
}

1;
