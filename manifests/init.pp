class tutor {
  ensure_resource('class', 'tutor::base', { 'install_docker' => true })

	user { 'tutor':
	  ensure  => 'present',
		gid     => 'tutor',
		groups  => 'docker',
		require => [
		  Package["docker-ce"]
		]
	}
}
