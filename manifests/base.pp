class tutor::base (
	Boolean $install_docker
) {
	$docker_packages = ["docker-ce", "docker-ce-cli", "containerd.io", "docker-buildx-plugin", "docker-compose-plugin"]

  if $install_docker {
		$repo_config_cmd = 'yum-config-manager'
		exec { 'docker-repo':
	    command => "${repo_config_cmd} --add-repo https://download.docker.com/linux/rhel/docker-ce.repo",
	    creates => "/etc/yum.repos.d/docker-ce.repo",
	    path    => ['/usr/bin'],
	  }

		package { $docker_packages:
	    ensure  => 'installed',
	    require => [
	      Exec['docker-repo'],
	    ],
	  }
	}

	ensure_packages(['python3', 'python3-pip', 'libyaml-devel'])

	exec { 'tutor-install':
	  command => 'pip install "tutor[full]"',
		creates => "/usr/local/bin/tutor",
    path    => ['/usr/bin'],
		require => [
		  Package[$docker_packages],
			Package["python3-pip"]
		]
	}
}
