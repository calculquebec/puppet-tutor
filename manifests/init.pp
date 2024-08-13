class tutor (
  String $version = '18.1.3',
  Array[Tuple[String, String]] $config,
) {
  $tutor_user = 'tutor'
  $openedx_docker_repository = 'overhangio/openedx'

  ensure_resource('class', 'tutor::base', { 'install_docker' => true, 'tutor_version' => $version })

  group { "$tutor_user":
    ensure => 'present',
  }
  user { "$tutor_user":
    ensure     => 'present',
    gid        => "$tutor_user",
    groups     => 'docker',
    managehome => true,
    home       => "/$tutor_user",
    require    => [
      Package['docker-ce'],
      Group["$tutor_user"]
    ]
  }

  $config.each |$tuple| {
    $key   = $tuple[0]
    $value = $tuple[1]
    exec { "tutor_config_${key}":
      command => "tutor config save --set ${key}='${value}'",
      unless  => "grep '${key}: ${value}' $(tutor config printroot)/config.yml",
      user    => "$tutor_user",
      path    => ['/usr/bin', '/usr/local/bin']
    }
  }

  exec { "tutor_local_dc_pull":
    command => "tutor local dc pull",
    unless  => "docker images ${openedx_docker_repository} | grep ${version}",
    user    => "$tutor_user",
    path    => ['/usr/bin', '/usr/local/bin']
  }
}
