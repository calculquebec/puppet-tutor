class tutor {
  ensure_resource('class', 'tutor::base', { 'install_docker' => true })

  group { 'tutor':
    ensure => 'present',
  }
  user { 'tutor':
    ensure     => 'present',
    gid        => 'tutor',
    groups     => 'docker',
		managehome => true,
		home       => '/tutor'
    require    => [
      Package["docker-ce"],
      Group['tutor']
    ]
  }
}
