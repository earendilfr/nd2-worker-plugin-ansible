use strict;
use warnings;
use Module::Build;

Module::Build->new(
  module_name => 'App::NetdiscoX::Worker::Plugin::MakeAnsibleHosts',
  license     => 'bsd',
  dynamic_config => 0,
  create_readme => 1,
  configure_requires => {
    'ExtUtils::MakeMaker' => 0,
    'File::ShareDir::Install' => '0.06',
    'Module::Build' => '0.42',
  },
  build_requires => {
    'Module::Build' => '0.42',
  },
  requires => {
    'App::Netdisco' => '2.063001',
    'Dancer' => '1.3132',
    'File::ShareDir' => 0,
  },
  test_requires => {
    'Test::More' => '0.88',
    'Test::Distribution' => '0',
    'Test::Pod' => '0',
    'Test::Perl::Critic' => '0',
  },
  meta_merge => {
    resources => {
      homepage => 'http://netdisco.org/',
      bugtracker => 'https://github.com/earendilfr/nd2-worker-plugin-ansible/issues',
      repository => 'https://github.com/earendilfr/nd2-worker-plugin-ansible',
    },
  },
)->create_build_script;
