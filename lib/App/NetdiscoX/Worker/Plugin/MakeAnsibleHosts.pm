package App::NetdiscoX::Worker::Plugin::MakeAnsibleHosts;

use strict;
use warnings;

use Dancer ':syntax';
use Dancer::Plugin::DBIC;

use App::Netdisco::Worker::Plugin;
use aliased 'App::Netdisco::Worker::Status';

use Path::Class;
use List::Util qw/pairkeys pairfirst pairgrep/;
use File::Slurper qw/read_lines write_text/;
use App::Netdisco::Util::Permission 'check_acl_no';

use YAML::XS qw/DumpFile LoadFile/;
use Hash::Merge qw/merge/;

sub sort_hash {
  my ($hash) = @_;

  my $result = {};
  foreach my $key (sort { lc $a cmp lc $b } keys %$hash) {
    if (ref $hash->{$key} eq ref {}) {
      $result->{$key} = sort_hash($hash->{$key});
    } else {
      $result->{$key} = $hash->{$key};
    }
  }
  return $result;
}

register_worker({ phase => 'main' }, sub {
  my ($job, $workerconf) = @_;
  my $config = setting('ansible') || {};

  my $domain_suffix = join('|',setting('domain_suffix') || '');
  my $delimiter = $config->{delimiter} || ';';
  my $down_age  = $config->{down_age} || '1 day';
  my $default_group = $config->{default_group} || 'default';

  my $ansible_root = $config->{root_dir}
    || dir($ENV{NETDISCO_HOME}, 'ansible')->stringify;
  my $ansible_cvs = $config->{cvs} || '';

  # Generate the host variable
  my $devices = schema('netdisco')->resultset('Device')->search(undef, {
    '+columns' => { old =>
      \['age(LOCALTIMESTAMP, last_discover) > ?::interval', $down_age] },
  });

  $config->{groups}      ||= { default => 'any' };
  $config->{osmap}       ||= {};
  $config->{excluded}    ||= [];
  $config->{by_ip}       ||= [];
  $config->{by_hostname} ||= [];
  $config->{cleanup_host_vars} ||= 0;

  my $hosts_unicity = {};
  my $hosts_db = { all => { children => {} } };
  my $hosts_inv = {};
  my $os_groups = {};

  while (my $d = $devices->next) {
    if (check_acl_no($d, $config->{excluded})) {
      debug " skipping $d: device excluded of export";
      next;
    } elsif ($d->get_column('old')) {
      debug " skipping $d: old device not discovered since $down_age at least";
      next;
    }

    my $name = check_acl_no($d, $config->{by_ip}) ? $d->ip : ($d->dns || $d->name);
    $name =~ s/$domain_suffix$//;

    if (exists($hosts_unicity->{$name})) {
      debug " skipping $d: device excluded because already present in hosts file";
      next;
    }

    my ($os) =
      (pairkeys pairfirst { check_acl_no($d, $b) } %{ $config->{osmap} })
        || $d->os;

    if (not ($name and $os)) {
      debug " skipping $d: the name or os is not defined";
      next;
    }

    if (exists($hosts_db->{all}->{children}->{$os})) {
      $hosts_db->{all}->{children}->{$os}->{hosts}->{$name} = undef
    } else {
      $hosts_db->{all}->{children}->{$os}->{hosts} = { $name => undef };
    }
    while (my ($group,$filter) = each %{$config->{groups}} ) {
      if (check_acl_no($d,$filter)) {
        if (exists($hosts_db->{all}->{children}->{$group})) {
          $hosts_db->{all}->{children}->{$group}->{hosts}->{$name} = undef;
        } else {
          $hosts_db->{all}->{children}->{$group}->{hosts} = { $name => undef };
        }
      }
    }

    $hosts_inv->{$name} = {
      ansible_host => check_acl_no($d, $config->{by_hostname}) ? $d->dns : $d->ip,
      snmp_location => $d->location,
    };

    $hosts_unicity->{$name} = 1;
  }

  # Sort data
  $hosts_db = sort_hash($hosts_db);

  # Write the ansible Host file
  if (! -d $ansible_root && ! mkdir $ansible_root) {
    return Status->error('Unable to create the ansible_root directory');
  }
  if (! -d "$ansible_root/host_vars" && !mkdir "$ansible_root/host_vars") {
    return Status->error('Unable to create the host_vars directory in ansible_root directory');
  }

  if ($ansible_cvs) {
    # <TODO>
  }

  eval { DumpFile("${ansible_root}/hosts",$hosts_db); };
  if ($@) { return Status->error("Unable to write file ${ansible_root}/hosts: $!"); }

  while(my ($host, $vars) = each %$hosts_inv) {
    eval {
      if (-f "${ansible_root}/host_vars/$host.yml") {
        $hosts_inv->{$host} = merge($hosts_inv->{$host},LoadFile("${ansible_root}/host_vars/$host.yml"));
      }
      DumpFile("${ansible_root}/host_vars/$host.yml",$hosts_inv->{$host}); 
    };
    if ($@) { return Status->error("Unable to read/write file ${ansible_root}/host_vars/$host.yml: $!"); }
  }

  # Clean-up old files if required
  if ($config->{cleanup_host_vars}) {
    use File::Basename qw(fileparse);
    foreach my $file (glob( "${ansible_root}/host_vars/*.yml")) {
      my ($f_host,$f_path,$f_suffix) = fileparse($file,".yml");
      unlink($file) if (!exists($hosts_inv->{$f_host}));
    }
  }

  return Status->done('Wrote ansible hosts and variables.');
});

true;

__END__

=pod

=cut

=encoding utf8

=head1 NAME

MakeAnsibleHosts - Generate ansible hosts file

=head1 SYNOPSIS

# in your ~/environments/deployment.yml file

extra_worker_plugins:
  -  X::MakeAnsibleHosts

plugin_ansible:
  root_dir: '/opt/ansible'
  down_age: '7 days'
  excluded: [ 'group:ansible_exclude' ]
  by_hostname: [ 'group:__ANY__' ]
  groups:
    'group1':
      - 'group:netdisco_group'
  osmap:
    'os_ansible':
      - 'os:netdisco_os'

=head1 Description

This is a plugin for the L<App::Netdisco> network management application.
It adds a worker to export the Devices seen by Netdisco to an ansible hosts
inventory to use it with ansible playbooks.

In the hosts file, the devices are sorted in two groups:
- group by OS
- group by name selector

=head1 Configuration

Create an entry in your C<~/environments/deployment.yml> file named
"C<plugin_ansible>", containing the following settings:

=head2 C<root_dir>

Value: String. Default: "$ENV{NETDISCO_HOME}/ansible"

Location where will be created the hosts file.
The default value is ansible directory in the under the NETDISCO_HOME dir

=head2 C<down_age>

This should be the same or greater than the interval between regular discover
jobs on your network. Devices which have not been discovered within this time
will be excluded from export to ansible host

The format is any time interval known and understood by PostgreSQL, such as at
L<https://www.postgresql.org/docs/10/static/functions-datetime.html>.

=head2 C<groups>

This dictionary maps ansible group names with configuration which will match
devices in the Netdisco database.

The left hand side (key) should be the ansible group name, the right hand side
(value) should be a L<Netdisco 
ACL|https://github.com/netdisco/netdisco/wiki/Configuration#access-control-lists>
to select devices in the Netdisco database.

=head2 C<excluded>

L<Netdisco
ACL|https://github.com/netdisco/netdisco/wiki/Configuration#access-control-lists>
to identify devices that will be excluded from the Ansible hosts

=head2 C<by_ip>

L<Netdisco
ACL|https://github.com/netdisco/netdisco/wiki/Configuration#access-control-lists> 
to select devices that will be written to the host file as an IP address 
instead of DNS FQDN or SNMP hostname.

=head2 C<by_hostname>

L<Netdisco
ACL|https://github.com/netdisco/netdisco/wiki/Configuration#access-control-lists> 
to select devices which will have the unqualified hostname written to the 
L<ansible_host|https://docs.ansible.com/ansible/latest/reference_appendices/special_variables.html#term-ansible_host> host_var file instead of the IP address.

=head2 C<osmap>

If the device vendor in Netdisco is not the same as the os defined in Ansible.
Mainly used to map devices with the correct module to ansible.

The left hand side (key) should be the ansible group, the right hand side
(value) should be a L<Netdisco
ACL|https://github.com/netdisco/netdisco/wiki/Configuration#access-control-lists>
to select devices in the Netdisco database.

=head1 SEE ALSO

L<https://docs.ansible.com/ansible/latest/inventory_guide/index.html>,

=head1 AUTHOR

Ambroise Rosset <earendil@toleressea.fr>

=head1 LICENSE AND COPYRIGHT

This software is copyright (c) 2013,2019 by The Netdisco Developer Team.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the Netdisco Project nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THE NETDISCO DEVELOPER TEAM BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut

# vim: shiftwidth=2 tabstop=2 expandtab
