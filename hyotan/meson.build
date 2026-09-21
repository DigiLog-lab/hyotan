# iOS runtime layer. Built only with -Dhyotan=true, from a cross file that
# names an Objective-C compiler. Produces libhyotan.a, which links against
# libish, libish_emu and libfakefs.
add_languages('objc', native: false)

version_h = vcs_tag(
    input: 'bridge/hyotan-version.h.in',
    output: 'hyotan-version.h',
    command: ['git', 'describe', '--tags', '--always', '--dirty'],
    fallback: 'unknown')

hyotan_defs = [
    '-DGUEST_' + guest_arch.to_upper() + '=1',
    '-DENGINE_' + get_option('engine').to_upper() + '=1',
    '-DLOG_HANDLER_' + get_option('log_handler').to_upper() + '=1',
]

libhyotan = library('hyotan',
    ['bridge/HyotanRuntime.m', version_h],
    include_directories: [includes, include_directories('include')],
    objc_args: hyotan_defs + ['-fobjc-arc', '-Wno-switch'])
