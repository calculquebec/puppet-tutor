type PythonPackageDef = Struct[
  {
    'name'   => String,
    'ensure' => String,
    'source' => Optional[String],
  }
]
type TutorPlugin = Struct[
  {
    'rebuild_image_on_content_change' => Optional[Boolean],
    'reboot_on_change'        => Optional[Boolean],
    'content'                 => Optional[String],
    'image'                   => Optional[String],
    'enabled'                 => Optional[Boolean],
    'pip_dep'                 => Optional[PythonPackageDef],
  }
]
define tutor::plugin (
  String $content = '',
  String $image = '',
  Boolean $rebuild_image_on_content_change = false,
  Boolean $reboot_on_change = false,
  Boolean $enabled = true,
  Optional[PythonPackageDef] $pip_dep = undef,
) {
  $tutor_user = $tutor::tutor_user
  $tutor_plugins_dir = $tutor::tutor_plugins_dir

  if $content != '' {
    file { "${tutor_plugins_dir}/${title}.py":
      ensure  => 'present',
      owner   => $tutor_user,
      group   => $tutor_user,
      require => File[$tutor_plugins_dir],
      before  => Exec["tutor_plugins_enable_${title}"],
      content => $content,
    }
    if $rebuild_image_on_content_change and $image != '' {
      File["${tutor_plugins_dir}/${title}.py"] ~> Exec['tutor_config_save'] ~> Exec["tutor_images_rebuild_${image}_for_${title}"]
    }
    else {
      File["${tutor_plugins_dir}/${title}.py"] ~> Exec['tutor_config_save']
    }
  }

  if $pip_dep {
    package { $pip_dep['name']:
      ensure   => $pip_dep['ensure'],
      name     => $pip_dep['name'],
      provider => 'pip3',
      require  => [Package['tutor'], Package['python3-pip']],
      source   => $pip_dep['source'],
      before   => Exec["tutor_plugins_enable_${title}"],
    }
    if $rebuild_image_on_content_change and $image != '' {
      Package[$pip_dep['name']] ~> Exec['tutor_config_save'] ~> Exec["tutor_images_rebuild_${image}_for_${title}"]
    }
    else {
      Package[$pip_dep['name']] ~> Exec['tutor_config_save']
    }
  }

  if $enabled {
    $action = 'enable'
    $check = 'enabled'
  }
  else {
    $action = 'disable'
    $check = 'installed'
  }
  exec { "tutor_plugins_${action}_${title}":
    command     => "tutor plugins ${action} ${title}",
    unless      => "tutor plugins list | grep -w ${title} | grep -w ${check}",
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    notify      => ($reboot_on_change ? {
                     false => Exec['tutor_config_save'],
                     true  => Exec['tutor_config_save', 'tutor local reboot --detach'],
                   }),
    require     => $require,
  }

  if $image != '' {
    if $rebuild_image_on_content_change {
      exec { "tutor_images_rebuild_${image}_for_${title}":
        command     => "tutor images build ${image}",
        user        => $tutor_user,
        refreshonly => true,
        path        => ['/usr/bin', '/usr/local/bin'],
        timeout     => 1800,
        notify      => Exec['tutor local reboot --detach'],
      }
    }
    # need to build at least once if it does not exist
    exec { "tutor_images_build_${image}_for_${title}":
      command     => "tutor images build ${image}",
      unless      => "docker images | grep -w ${image}",
      user        => $tutor_user,
      path        => ['/usr/bin', '/usr/local/bin'],
      timeout     => 1800,
      notify      => Exec['tutor local reboot --detach'],
    }
  }
}
class tutor (
  String $tutor_user = 'tutor',
  String $tutor_plugins_dir = "/${tutor_user}/.local/share/tutor-plugins",
  String $tutor_backup_dir = "/${tutor_user}/.local/share/tutor/env/backup/",
  String $tutor_contrib_backup_version = '3.3.0',
  String $version = '18.1.3',
  Hash[String, String] $config,
  Optional[Hash[String, Array[String]]] $env_patches = undef,
  Array[String] $openedx_extra_pip_requirements = [],
  String $brand_theme_url = '',
  String $admin_password,
  String $admin_email,
  Optional[Struct[{ date => String[1], path => String[1] }]] $backup_to_restore = undef,
  Optional[Array[String]] $registration_email_patterns_allowed = undef,
  Optional[Hash[String, Optional[TutorPlugin]]] $plugins = undef,
  Optional[String] $upgrade_from = undef,
) {
  $openedx_docker_repository = 'overhangio/openedx'

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

  $config.each |$key, $value| {
    exec { "tutor_config_${key}":
      command => "tutor config save --set ${key}=\"${value}\"",
      unless  => "test \"$(tutor config printvalue ${key})\" == \"${value}\"",
      user    => $tutor_user,
      path    => ['/usr/bin', '/usr/local/bin'],
      notify  => Exec['tutor local exec lms reload-uwsgi']
    }
  }

  if $openedx_extra_pip_requirements != [] {
    $key = 'OPENEDX_EXTRA_PIP_REQUIREMENTS'
    $str_value = join($openedx_extra_pip_requirements, '\', \'')
    $value = "['${str_value}']"
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
    notify      => Exec['tutor local reboot --detach'],
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
  <% $env_patches.each |$key, $values| { %>
  <% $values.each |$value| { %>
  hooks.Filters.ENV_PATCHES.add_item(("<%= $key %>", """<%= $value %>"""))
  <% } %>
  <% } %>
  |END
  tutor::plugin { 'puppet_tutor':
    content => inline_epp($puppet_tutor_py_template),
    notify  => Exec['tutor_config_save'],
  }

  if $registration_email_patterns_allowed {
    $registration_email_plugin_template = @(END)
    from tutor import hooks
    hooks.Filters.ENV_PATCHES.add_item(("openedx-common-settings", """
REGISTRATION_EMAIL_PATTERNS_ALLOWED = [
    <%- $registration_email_patterns_allowed.each |$index, $pattern| { -%>
    "<%= $pattern %>",
    <%- } -%>
    ]"""))
    |END
    tutor::plugin { 'registration_email_patterns_allowed':
      content           => inline_epp($registration_email_plugin_template),
    }
  }

  if $plugins {
    ensure_resources(tutor::plugin, $plugins)
  }

  tutor::plugin { 'backup':
    image   => 'backup',
    pip_dep => {
                 'name'   => 'tutor-contrib-backup',
                 'source' => 'git+https://github.com/hastexo/tutor-contrib-backup',
                 'ensure' => "v${tutor_contrib_backup_version}",
               }
  }

  if $brand_theme_url != '' {
    $brand_theme_patch = @("END")
    from tutor import hooks
    hooks.Filters.ENV_PATCHES.add_item(("mfe-dockerfile-post-npm-install-authn", """
    RUN npm install '@edx/brand@${brand_theme_url}'
    """))
    |END
    tutor::plugin { 'brand_theme':
      image                           => 'mfe',
      rebuild_image_on_content_change => true,
      content                         => $brand_theme_patch,
    }
  }

  if $backup_to_restore {
    $date = $backup_to_restore['date']
    $path = $backup_to_restore['path']
    $filename = "backup.${date}.tar.xz"
    exec { "cp ${path}/${filename} ${tutor_backup_dir}":
      unless      => "grep -w ${date} /${tutor_user}/.backup_restored",
      require     => [Tutor::Plugin['backup']],
      onlyif      => "test -f /${tutor_user}/.first_init_run",
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
      notify      => Exec['tutor local do init']
    }
    file { "/${tutor_user}/.backup_restored":
      ensure  => file,
      content => $date,
      require => Exec["tutor local restore --date ${date}"],
    }
  }

  if $upgrade_from {
    exec { 'upgrade_tutor_config_save':
      command     => 'tutor config save',
      user        => $tutor_user,
      path        => ['/usr/bin', '/usr/local/bin'],
      unless      => "grep ${upgrade_from} /${tutor_user}/.upgraded_from",
      subscribe   => Package['tutor'],
      refreshonly => true,
    }
    exec { "tutor images build all":
      unless  => "grep ${upgrade_from} /${tutor_user}/.upgraded_from",
      require => Exec['upgrade_tutor_config_save'],
      notify  => Exec["tutor local upgrade --from=${upgrade_from}"],
      user    => $tutor_user,
      path    => ['/usr/bin', '/usr/local/bin'],
      timeout => 1800
    }
    exec { "tutor local upgrade --from=${upgrade_from}":
      refreshonly => true,
      user        => $tutor_user,
      path        => ['/usr/bin', '/usr/local/bin'],
    }
    file { "/${tutor_user}/.upgraded_from":
      ensure  => file,
      content => $upgrade_from,
      require => Exec["tutor local upgrade --from=${upgrade_from}"],
      notify  => Exec["tutor local dc pull"]
    }
  }

  exec { 'tutor_config_save':
    command     => 'tutor config save',
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    notify      => Exec['tutor local exec lms reload-uwsgi'],
    subscribe   => Package['tutor'],
    refreshonly => true,
  }

  exec { 'tutor local dc pull':
    unless  => "docker images ${openedx_docker_repository} | grep ${version}",
    user    => $tutor_user,
    path    => ['/usr/bin', '/usr/local/bin'],
    notify  => [Exec['tutor local do init'], Exec['tutor_create_admin']]
  }

  exec { 'tutor local do init':
    user         => $tutor_user,
    path         => ['/usr/bin', '/usr/local/bin'],
    refreshonly  => true,
    timeout      => 1800
  }
  file { "/${tutor_user}/.first_init_run":
    ensure  => file,
    require => Exec['tutor local do init'],
  }

  exec { 'tutor_create_admin':
    command     => "tutor local do createuser --staff --superuser admin ${admin_email} --password ${admin_password}",
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    unless      => "grep ${admin_email} /${tutor_user}/.admin_created",
    onlyif      => "tutor local status | grep tcp",
  }
  file { "/${tutor_user}/.admin_created":
    ensure  => file,
    content => $admin_email,
    require => Exec['tutor_create_admin'],
  }

  exec { 'tutor local start --detach':
    user    => $tutor_user,
    unless  => "tutor local status | grep overhangio/openedx | grep tcp",
    path    => ['/usr/bin', '/usr/local/bin'],
    require => File["/${tutor_user}/.first_init_run"],
  }

  exec { 'tutor local reboot --detach':
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    refreshonly => true,
  }

  exec { 'tutor local exec lms reload-uwsgi':
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    require     => File["/${tutor_user}/.first_init_run"],
    refreshonly => true,
  }
}
