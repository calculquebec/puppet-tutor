define tutor::plugin (
  String $tutor_user = 'tutor',
  String $tutor_plugins_dir = "/${tutor_user}/.local/share/tutor-plugins",
  String $content = '',
  String $image = '',
  Boolean $build_image_on_change = false,
) {

  if $content != '' {
    file { "${tutor_plugins_dir}/${title}.py":
      ensure  => 'present',
      owner   => $tutor_user,
      group   => $tutor_user,
      require => File[$tutor_plugins_dir],
      content => $content,
      notify  => ($image == '' ? {
                     true => Exec["tutor_plugins_enable_${title}"],
                     false => Exec["tutor_plugins_enable_${title}", "tutor_images_build_${image}"],
                 }),
    }
  }

  exec { "tutor_plugins_enable_${title}":
    command     => "tutor plugins enable ${title}",
    unless      => "tutor plugins list | grep -w ${title} | grep -w enabled",
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    notify      => ($image == '' ? {
                     true  => Exec['tutor_config_save'],
                     false => Exec['tutor_config_save', "tutor_images_build_${image}"],
                   }),
    require     => $require,
  }

  if $image != '' {
    if $build_image_on_change {
      exec { "tutor_images_build_${image}":
        command     => "tutor images build ${image}",
        user        => $tutor_user,
        refreshonly => true,
        path        => ['/usr/bin', '/usr/local/bin'],
        timeout     => 1800,
        notify      => Exec['tutor_local_reboot'],
      }
    }
    else {
      exec { "tutor_images_build_${image}":
        command     => "tutor images build ${image}",
        unless      => "docker images | grep -w ${image}",
        user        => $tutor_user,
        refreshonly => true,
        path        => ['/usr/bin', '/usr/local/bin'],
        timeout     => 1800,
      }
    }
  }
}
class tutor (
  String $version = '18.1.3',
  Array[Tuple[String, String]] $config,
  Array[Tuple[String, String]] $env_patches = [],
  String $openedx_extra_pip_requirements = '',
  String $brand_theme_url = '',
  String $admin_password,
  String $admin_email,
  Optional[Struct[{ date => String[1], path => String[1] }]] $backup_to_restore = undef,
) {
  $tutor_user = 'tutor'
  $openedx_docker_repository = 'overhangio/openedx'
  $tutor_plugins_dir = "/${tutor_user}/.local/share/tutor-plugins"
  $tutor_backup_dir = "/${tutor_user}/.local/share/tutor/env/backup/"
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
      command => "tutor config save --set ${key}=\"${value}\"",
      unless  => "test \"$(tutor config printvalue ${key})\" == \"${value}\"",
      user    => $tutor_user,
      path    => ['/usr/bin', '/usr/local/bin'],
      notify  => Exec['tutor_local_exec_lms_reload-uwsgi']
    }
  }

  if $openedx_extra_pip_requirements != '' {
    $key = 'OPENEDX_EXTRA_PIP_REQUIREMENTS'
    $value = $openedx_extra_pip_requirements
    exec { "tutor_config_${key}_${value}":
      command => "tutor config save --set ${key}=\"${value}\"",
      unless  => "test \"$(tutor config printvalue ${key})\" == \"${value}\"",
      user    => $tutor_user,
      path    => ['/usr/bin', '/usr/local/bin'],
      notify  => Exec['tutor_images_build_openedx']
    }
  }
  exec { "tutor_images_build_openedx":
    command     => "tutor images build openedx",
    user        => $tutor_user,
    refreshonly => true,
    path        => ['/usr/bin', '/usr/local/bin'],
    timeout     => 1800,
    notify      => Exec['tutor_local_reboot'],
  }

  file { $tutor_plugins_dir:
    ensure => 'directory',
    owner  => $tutor_user,
    group  => $tutor_user,
  }
  file { $tutor_backup_dir:
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
  tutor::plugin { 'puppet_tutor':
    tutor_user        => $tutor_user,
    tutor_plugins_dir => $tutor_plugins_dir,
    content           => inline_epp($puppet_tutor_py_template),
  }

  tutor::plugin { 'backup':
    tutor_user => $tutor_user,
    image      => 'backup',
    require    => Package['tutor-contrib-backup'],
  }

  if $brand_theme_url != '' {
    $brand_theme_patch = @("END")
    from tutor import hooks
    hooks.Filters.ENV_PATCHES.add_item(("mfe-dockerfile-post-npm-install-authn", """
    RUN npm install '@edx/brand@${brand_theme_url}'
    """))
    |END
    tutor::plugin { 'brand_theme':
      tutor_user            => $tutor_user,
      image                 => 'mfe',
      build_image_on_change => true,
      content               => $brand_theme_patch,
    }
  }

  if $backup_to_restore {
    $date = $backup_to_restore['date']
    $path = $backup_to_restore['path']
    $filename = "backup.${date}.tar.xz"
    file { "/${tutor_user}/.backup_restored":
      ensure  => file,
      content => $date,
      notify  => Exec["cp ${path}/${filename} ${tutor_backup_dir}"]
    }
    exec { "cp ${path}/${filename} ${tutor_backup_dir}":
      refreshonly => true,
      path        => ['/bin/', '/usr/bin'],
      notify      => Exec["chown -R root:root ${tutor_backup_dir}/${filename}"],
    }
    exec { "chown -R root:root ${tutor_backup_dir}/${filename}":
      refreshonly => true,
      path        => ['/bin/', '/usr/bin'],
      notify      => Exec["tutor local restore --date ${date}"]
    }
    exec { "tutor local restore --date ${date}":
      refreshonly => true,
      user        => $tutor_user,
      path        => ['/usr/bin', '/usr/local/bin'],
      notify      => Exec['tutor_local_do_init']
    }
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
    path    => ['/usr/bin', '/usr/local/bin'],
    notify  => [Exec['tutor_local_do_init'], Exec['tutor_create_admin']]
  }

  exec { 'tutor_local_do_init':
    command      => 'tutor local do init',
    unless       => "tutor local status | grep tcp",
    user         => $tutor_user,
    path         => ['/usr/bin', '/usr/local/bin'],
    notify       => [Exec['tutor_create_admin']],
    refreshonly => true,
    timeout      => 1800
  }

  exec { 'tutor_create_admin':
    command     => "tutor local do createuser --staff --superuser admin ${admin_email} --password ${admin_password}",
    onlyif      => "tutor local status | grep tcp",
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    require     => Exec['tutor_local_do_init'],
    refreshonly => true,
  }

  exec { 'tutor_local_start':
    command => 'tutor local start --detach',
    user    => $tutor_user,
    unless  => "tutor local status | grep overhangio/openedx | grep tcp",
    path    => ['/usr/bin', '/usr/local/bin'],
    require => Exec['tutor_local_do_init'],
  }

  exec { 'tutor_local_reboot':
    command     => 'tutor local reboot --detach',
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    refreshonly => true,
  }

  exec { 'tutor_local_exec_lms_reload-uwsgi':
    command     => 'tutor local exec lms reload-uwsgi',
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    refreshonly => true,
  }
}
