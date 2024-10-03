class tutor (
  String $version = '18.1.3',
  Array[Tuple[String, String]] $config,
  Array[Tuple[String, String]] $env_patches,
) {
  $tutor_user = 'tutor'
  $openedx_docker_repository = 'overhangio/openedx'
  $tutor_plugins_dir = "/${tutor_user}/.local/share/tutor-plugins"
  $puppet_tutor_py = "/${tutor_plugins_dir}/puppet_tutor.py"

  ensure_resource('class', 'tutor::base', { 'install_docker' => true, 'tutor_version' => $version })

  group { $tutor_user:
    ensure => 'present',
  }
  user { $tutor_user:
    ensure     => 'present',
    gid        => $tutor_user,
    groups     => 'docker',
    managehome => true,
    home       => "/$tutor_user",
    require    => [
      Package['docker-ce'],
      Group[$tutor_user]
    ]
  }

  $config.each |$tuple| {
    $key   = $tuple[0]
    $value = $tuple[1]
    exec { "tutor_config_${key}":
      command => "tutor config save --set ${key}='${value}'",
      unless  => "grep '${key}: ${value}' $(tutor config printroot)/config.yml",
      user    => $tutor_user,
      path    => ['/usr/bin', '/usr/local/bin'],
      notify  => Exec['tutor_local_exec_lms_reload-uwsgi']
    }
  }

  file { $tutor_plugins_dir:
    ensure => 'directory',
    owner  => $tutor_user,
    group  => $tutor_user,
  }

  $puppet_tutor_py_template = @(END)
  from tutor import hooks
  <% $env_patches.each |$tuple| { %>
  hooks.Filters.ENV_PATCHES.add_item(("<%= $tuple[0] %>", "<%= $tuple[1] %>"))
  <% } %>
  |END
  file { $puppet_tutor_py:
    ensure  => 'present',
    owner   => $tutor_user,
    group   => $tutor_user,
    require => File[$tutor_plugins_dir],
    content => inline_epp($puppet_tutor_py_template),
  }

  exec { 'tutor_plugins_enable':
    command => 'tutor plugins enable puppet_tutor',
    unless  => 'tutor plugins list | grep puppet_tutor | grep enabled',
    user    => $tutor_user,
    path    => ['/usr/bin', '/usr/local/bin'],
    require => File[$puppet_tutor_py],
    notify  => Exec['tutor_config_save'],
  }

  exec { 'tutor_config_save':
    command     => 'tutor config save',
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    notify      => Exec['tutor_local_exec_lms_reload-uwsgi'],
    refreshonly => true,
  }

  exec { 'tutor_local_dc_pull':
    command => "tutor local dc pull",
    unless  => "docker images ${openedx_docker_repository} | grep ${version}",
    user    => $tutor_user,
    path    => ['/usr/bin', '/usr/local/bin']
  }

  exec { 'tutor_local_do_init':
    command => 'tutor local do init',
    unless  => "tutor local status | grep tcp",
    user    => $tutor_user,
    path    => ['/usr/bin', '/usr/local/bin'],
    require => Exec['tutor_local_dc_pull'],
    timeout => 1800
  }

  exec { 'tutor_local_start':
    command => 'tutor local start --detach',
    user    => $tutor_user,
    unless  => "tutor local status | grep overhangio/openedx | grep tcp",
    path    => ['/usr/bin', '/usr/local/bin'],
    require => Exec['tutor_local_do_init'],
  }

  exec { 'tutor_local_exec_lms_reload-uwsgi':
    command     => 'tutor local exec lms reload-uwsgi',
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    require     => Exec['tutor_local_start'],
    refreshonly => true,
  }
}