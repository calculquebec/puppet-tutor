type PythonPackageDef = Struct[
  {
    'name'   => String,
    'ensure' => String,
    'source' => Optional[String],
  }
]
type PluginFileURL = Struct[
  {
    'url' =>  String[1],
  }
]
type TutorPlugin = Struct[
  {
    'reboot_on_change' => Optional[Boolean],
    'reinit_on_change' => Optional[Boolean],
    'enabled'          => Optional[Boolean],
    'images'           => Optional[Array[String]],
    'dep'              => Variant[PluginFileURL, String[1], PythonPackageDef],
  }
]
define tutor::plugin_dep (
  Variant[PluginFileURL, String[1], PythonPackageDef] $dep
) {
  $tutor_user = $tutor::tutor_user
  $tutor_plugins_dir = $tutor::tutor_plugins_dir
  if $dep.is_a(PluginFileURL) {
    exec { "cp ${tutor_plugins_dir}/${title}.download ${tutor_plugins_dir}/${title}.py":
      unless  => "diff ${tutor_plugins_dir}/${title}.download ${tutor_plugins_dir}/${title}.py",
      user    => $tutor_user,
      path    => ['/usr/bin', '/usr/local/bin'],
      notify  => Exec['tutor config save'],
      require => File["${tutor_plugins_dir}/${title}.download"],
    }
  }
  if $dep.is_a(String) {
    file { "${tutor_plugins_dir}/${title}.py":
      ensure  => 'present',
      owner   => $tutor_user,
      group   => $tutor_user,
      require => File[$tutor_plugins_dir],
      notify  => Exec['tutor config save'],
      content => $dep,
    }
  }
  if $dep.is_a(PythonPackageDef) {
    package { $dep['name']:
      ensure   => $dep['ensure'],
      name     => $dep['name'],
      provider => 'pip3',
      require  => [Package['tutor'], Package['python3-pip']],
      before   => Exec['tutor config save'],
      source   => $dep['source'],
    }
  }
}
define tutor::plugin (
  Array[String] $images = [],
  Boolean $reboot_on_change = false,
  Boolean $reinit_on_change = false,
  Boolean $enabled = true,
  Variant[PluginFileURL, String[1], PythonPackageDef] $dep,
) {
  $tutor_user = $tutor::tutor_user
  $tutor_plugins_dir = $tutor::tutor_plugins_dir

  if $dep.is_a(PluginFileURL) {
    file { "${tutor_plugins_dir}/${title}.download":
      ensure   => 'present',
      owner    => $tutor_user,
      group    => $tutor_user,
      require  => File[$tutor_plugins_dir],
      source   => $dep['url'],
    }
  }
  tutor::plugin_dep { $title: dep => $dep }

  if $enabled {
    $action = 'enable'
    $check = 'enabled'
    # ensure all plugins deps have been updated before this action
    Tutor::Plugin_dep <||> -> Exec["tutor_plugins_${action}_${title}"]
  }
  else {
    $action = 'disable'
    $check = 'installed'
  }
  exec { "tutor_plugins_${action}_${title}":
    command => "tutor plugins ${action} ${title}",
    unless  => "tutor plugins list | grep -w ${title} | grep -w ${check}",
    user    => $tutor_user,
    path    => ['/usr/bin', '/usr/local/bin'],
    notify  => ($reboot_on_change ? {
                  false => Exec['tutor config save'],
                  true  => Exec['tutor config save', 'tutor local reboot --detach'],
                }),
    before  => Exec['tutor config save'],
    require => $require,
  }
  if $reinit_on_change {
    Exec["tutor_plugins_${action}_${title}"] ~> Exec['tutor local do init']
  }

  $images.each |String $image| {
    Tutor::Plugin_dep[$title] ~> Exec["tutor images rebuild ${image}"]
    if $image == 'openedx' {
      $options = '--no-cache'
    }
    else {
      $options = ''
    }
    ensure_resource('exec', "tutor images rebuild ${image}", {
        command     => "tutor images build ${image} ${options}",
        user        => $tutor_user,
        refreshonly => true,
        path        => ['/usr/bin', '/usr/local/bin'],
        timeout     => 1800,
        require     => Exec['tutor config save'],
    })
    if $reboot_on_change {
      Exec["tutor images rebuild ${image}"] ~> Exec['tutor local reboot --detach']
    }
    if $reinit_on_change {
      Exec["tutor images rebuild ${image}"] ~> Exec['tutor local do init']
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
      notify  => Exec['tutor images build openedx']
    }
  }
  exec { "tutor images build openedx":
    command     => "tutor images build openedx",
    user        => $tutor_user,
    refreshonly => true,
    path        => ['/usr/bin', '/usr/local/bin'],
    timeout     => 1800,
    require     => File["/${tutor_user}/.first_init_run"],
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
    dep     => inline_epp($puppet_tutor_py_template),
    notify  => Exec['tutor config save'],
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
      dep => inline_epp($registration_email_plugin_template),
    }
  }

  if $plugins {
    ensure_resources(tutor::plugin, $plugins)
  }

  tutor::plugin { 'backup':
    images  => ['backup'],
    dep     => {
                 'name'   => 'tutor-contrib-backup',
                 'source' => 'git+https://github.com/hastexo/tutor-contrib-backup',
                 'ensure' => "v${tutor_contrib_backup_version}",
               },
    require => File["/${tutor_user}/.first_init_run"]
  }

  if $brand_theme_url != '' {
    $brand_theme_patch = @("END")
    from tutor import hooks
    hooks.Filters.ENV_PATCHES.add_item(("mfe-dockerfile-post-npm-install-authn", """
    RUN npm install '@edx/brand@${brand_theme_url}'
    """))
    |END
    tutor::plugin { 'brand_theme':
      images => ['mfe'],
      dep    => $brand_theme_patch,
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
      require => [Tutor::Plugin['backup'], Exec["tutor local restore --date ${date}"]],
    }
  }

  if $upgrade_from {
    # ensure all plugs have updated
    Tutor::Plugin_dep <||> -> Exec['upgrade_tutor_config_save']
    exec { 'upgrade_tutor_config_save':
      command     => 'tutor config save',
      user        => $tutor_user,
      path        => ['/usr/bin', '/usr/local/bin'],
      unless      => "grep ${upgrade_from} /${tutor_user}/.upgraded_from",
      subscribe   => [Package['tutor'], Tutor::Plugin['backup']],
      refreshonly => true,
    }
    exec { "tutor images build all":
      unless  => "grep ${upgrade_from} /${tutor_user}/.upgraded_from",
      require => Exec['upgrade_tutor_config_save'],
      notify  => Exec["tutor local upgrade --from=${upgrade_from}"],
      user    => $tutor_user,
      path    => ['/usr/bin', '/usr/local/bin'],
      timeout => 3600
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

  exec { 'tutor config save':
    command     => 'tutor config save',
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    notify      => Exec['tutor local exec lms reload-uwsgi'],
    subscribe   => Package['tutor'],
    before      => Exec['tutor local dc pull'],
    refreshonly => true,
  }

  exec { 'tutor local dc pull':
    unless    => "docker images ${openedx_docker_repository} | grep openedx",
    onlyif    => "test -f /${tutor_user}/.first_init_run}",
    user      => $tutor_user,
    path      => ['/usr/bin', '/usr/local/bin'],
    subscribe => Package['tutor'],
    notify    => [Exec['tutor local do init']],
    before    => [Exec['tutor local exec lms reload-uwsgi']]
  }

  exec { 'first tutor local dc pull':
    command => 'tutor local dc pull',
    unless  => "docker images ${openedx_docker_repository} | grep openedx",
    onlyif  => "test ! -f /${tutor_user}/.first_init_run}",
    user    => $tutor_user,
    path    => ['/usr/bin', '/usr/local/bin'],
    notify  => [Exec['first tutor local do init'], Exec['tutor_create_admin']]
  }

  exec { 'tutor local do init':
    user        => $tutor_user,
    path        => ['/usr/bin', '/usr/local/bin'],
    refreshonly => true,
    timeout     => 1800,
    subscribe   => [Exec['tutor local dc pull']],
    before      => [Exec['tutor local exec lms reload-uwsgi']]
  }
  exec { 'first tutor local do init':
    command      => 'tutor local do init',
    user         => $tutor_user,
    path         => ['/usr/bin', '/usr/local/bin'],
    refreshonly  => true,
    timeout      => 1800
  }
  file { "/${tutor_user}/.first_init_run":
    ensure  => file,
    require => Exec['first tutor local do init'],
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
