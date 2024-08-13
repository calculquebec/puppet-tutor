class tutor (
  String $version = "18.1.3"
) {
  ensure_resource('class', 'tutor::base', { 'install_docker' => true, 'tutor_version' => $version })

  group { 'tutor':
    ensure => 'present',
  }
  user { 'tutor':
    ensure     => 'present',
    gid        => 'tutor',
    groups     => 'docker',
    managehome => true,
    home       => '/tutor',
    require    => [
      Package["docker-ce"],
      Group['tutor']
    ]
  }
}
