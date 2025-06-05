class tutor::base (
  Boolean $install_docker = true,
  String $tutor_version = '18.1.3',
) {
  $docker_packages = ['docker-ce', 'docker-ce-cli', 'containerd.io', 'docker-buildx-plugin', 'docker-compose-plugin']

  if $install_docker {
    $repo_config_cmd = 'dnf config-manager'
    exec { 'docker-repo':
      command => "${repo_config_cmd} --add-repo https://download.docker.com/linux/rhel/docker-ce.repo",
      creates => '/etc/yum.repos.d/docker-ce.repo',
      path    => ['/usr/bin'],
    }

    package { $docker_packages:
      ensure  => 'installed',
      require => [
        Exec['docker-repo'],
      ],
    }

    service { 'docker':
      ensure  => running,
      enable  => true,
      require => [
        Package[$docker_packages]
      ]
    }
  }

  ensure_packages(['python3.11', 'python3.11-pip', 'libyaml-devel'])
  file { '/usr/bin/pip3':
    target => '/usr/bin/pip3.11',
    ensure => 'link',
    before => Package['python3.11-pip'],
  }
  package { 'tutor':
    ensure   => "${tutor_version}",
    name     => 'tutor',
    provider => 'pip3',
    require  => [
      Service['docker'],
      Package['python3.11-pip']
    ]
  }
}
