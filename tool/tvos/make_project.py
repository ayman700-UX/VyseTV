"""Writes the Xcode project of the Apple TV app (tvos/Runner.xcodeproj and the workspace).

    python tool/tvos/make_project.py

One target, Runner, a tvOS app. The project is written whole from the lists below (no Xcode on
this PC to edit it with), so a file is added to the app by adding it here and running this
again. Object ids are made from names, so the output only changes where something changed.

What the target does, in order:
  Run Script     tvos/scripts/xcode_appletv.sh build: the app's Dart, assets, App.framework and
                 the engine's Flutter.framework (Flutter's tool has no Apple TV target)
  Sources        the Swift below
  Frameworks     MPVKit (libmpv and FFmpeg, the same package and revision as the iPhone app), and
                 TorrServerKit (the torrent engine: tvos/Frameworks, unpacked from
                 packages/torrserver_flutter/binaries/TorrServerKit-tvos.xcframework.zip)
  Resources      icons, storyboards
  Thin Binary    tvos/scripts/xcode_appletv.sh sync_version: version from pubspec.yaml, and
                 App.framework and Flutter.framework put into the app
"""
import hashlib
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
TVOS = REPO / 'tvos'
BUNDLE_ID = 'com.vyse.vyseTv'
# (17: the WebRTC build the voice call runs on has its Apple TV slices from tvOS 17. Every Apple TV
# that ran tvOS 15 runs 17.)
DEPLOYMENT = '17.0'

# The mpv package, pinned as in ios/Runner.xcodeproj (read from there, so the two never part).
IOS_PROJECT = REPO / 'ios' / 'Runner.xcodeproj' / 'project.pbxproj'

# Swift of the app's own folder (paths from tvos/Runner)
RUNNER_SOURCES = [
    'AppDelegate.swift',
    'AppleTvPlugin.swift',
    'Plugins/connectivity_plus/ConnectivityPlusPlugin.swift',
    'Plugins/connectivity_plus/ConnectivityProvider.swift',
    'Plugins/connectivity_plus/PathMonitorConnectivityProvider.swift',
    'Plugins/device_info_plus/DeviceInfoPlusPlugin.swift',
    'Plugins/flutter_secure_storage/KeychainPlugin.swift',
    'Plugins/package_info_plus/PackageInfoPlusPlugin.swift',
    'Plugins/path_provider/PathProviderPlugin.swift',
    'Plugins/shared_preferences_foundation/SharedPreferencesPlugin.swift',
    'Plugins/shared_preferences_foundation/messages.g.swift',
]
# Swift shared with the iPhone app (paths from the repository's root)
SHARED_SOURCES = [
    'ios/Runner/MpvPlayer/MpvAudioPlayerCore.swift',
    'ios/Runner/MpvPlayer/MpvAudioPlayerPlugin.swift',
    'ios/Runner/MpvPlayer/MpvPipController.swift',
    'ios/Runner/MpvPlayer/MpvPlayerCore.swift',
    'ios/Runner/MpvPlayer/MpvPlayerCoreBase.swift',
    'ios/Runner/MpvPlayer/MpvPlayerPlugin.swift',
    'ios/Runner/MpvPlayer/MpvPlayerPluginShared.swift',
    'packages/torrserver_flutter/ios/Classes/TorrserverFlutterPlugin.swift',
]
RESOURCES = ['Assets.xcassets', 'Base.lproj/LaunchScreen.storyboard', 'Base.lproj/Main.storyboard']

# Plugins copied whole by tool/tvos/vendor_plugins.py (a party's voice call): every source file in
# their folders under tvos/Runner/Plugins is compiled. Their Objective-C reaches the Swift through
# Runner/Runner-Bridging-Header.h.
TREE_PLUGINS = ['flutter_webrtc', 'livekit_client']
BRIDGING_HEADER = 'Runner/Runner-Bridging-Header.h'


def tree_sources():
    out = []
    for name in TREE_PLUGINS:
        root = TVOS / 'Runner' / 'Plugins' / name
        if not root.exists():
            raise SystemExit(f'{root} is missing: run python tool/tvos/vendor_plugins.py')
        out += sorted('Plugins/' + name + '/' + p.relative_to(root).as_posix() for p in root.rglob('*') if p.suffix in ('.m', '.mm', '.cpp', '.swift'))
    return out


def oid(*key):
    return hashlib.md5('/'.join(key).encode()).hexdigest()[:24].upper()


def q(value):
    """A value as the pbxproj writes it: bare when it can be, quoted otherwise."""
    if re.fullmatch(r'[A-Za-z0-9_./]+', value) and value:
        return value
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'


def file_type(path):
    ext = path.rsplit('.', 1)[-1]
    return {
        'swift': 'sourcecode.swift',
        'm': 'sourcecode.c.objc',
        'mm': 'sourcecode.cpp.objcpp',
        'cpp': 'sourcecode.cpp.cpp',
        'h': 'sourcecode.c.h',
        'xcframework': 'wrapper.xcframework',
        'xcassets': 'folder.assetcatalog',
        'storyboard': 'file.storyboard',
        'plist': 'text.plist.xml',
        'xcconfig': 'text.xcconfig',
        'app': 'wrapper.application',
    }[ext]


def mpv_package():
    text = IOS_PROJECT.read_text(encoding='utf-8')
    m = re.search(r'repositoryURL = "([^"]+mpv-build)";\s*requirement = \{\s*kind = revision;\s*revision = ([0-9a-f]{40});', text)
    if not m:
        raise SystemExit(f'no mpv-build revision pin in {IOS_PROJECT}')
    return m.group(1), m.group(2)


def build_settings(settings, indent):
    lines = []
    for key in sorted(settings):
        value = settings[key]
        if isinstance(value, list):
            lines.append(f'{indent}{q(key)} = (')
            lines += [f'{indent}\t{q(v)},' for v in value]
            lines.append(f'{indent});')
        else:
            lines.append(f'{indent}{q(key)} = {q(value)};')
    return '\n'.join(lines)


def main():
    url, revision = mpv_package()
    objects = {}  # section -> [(id, text)]

    def add(section, ident, text):
        objects.setdefault(section, []).append((ident, text))

    # ── files ──
    groups = {}  # group path -> list of child ids

    def file_ref(key, name, path, tree):
        ident = oid('file', key)
        add('PBXFileReference', ident,
            f'{ident} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type(path)}; '
            f'name = {q(name)}; path = {q(path)}; sourceTree = {q(tree)}; }};')
        return ident

    sources, resources = [], []
    runner_children = []
    plugin_groups = {}
    for rel in RUNNER_SOURCES + tree_sources():
        name = rel.rsplit('/', 1)[-1]
        ref = file_ref('Runner/' + rel, name, 'Runner/' + rel, 'SOURCE_ROOT')
        sources.append((ref, name))
        if rel.startswith('Plugins/'):
            plugin_groups.setdefault(rel.split('/')[1], []).append((ref, name))
        else:
            runner_children.append((ref, name))
    for rel in RESOURCES:
        name = rel.rsplit('/', 1)[-1]
        ref = file_ref('Runner/' + rel, name, 'Runner/' + rel, 'SOURCE_ROOT')
        resources.append((ref, name))
        runner_children.append((ref, name))
    info = file_ref('Runner/Info.plist', 'Info.plist', 'Runner/Info.plist', 'SOURCE_ROOT')
    runner_children.append((info, 'Info.plist'))
    shared_children = []
    for rel in SHARED_SOURCES:
        name = rel.rsplit('/', 1)[-1]
        ref = file_ref(rel, name, '../' + rel, 'SOURCE_ROOT')
        sources.append((ref, name))
        shared_children.append((ref, name))
    flutter_children = [
        (file_ref('Flutter/Debug.xcconfig', 'Debug.xcconfig', 'Flutter/Debug.xcconfig', 'SOURCE_ROOT'), 'Debug.xcconfig'),
        (file_ref('Flutter/Release.xcconfig', 'Release.xcconfig', 'Flutter/Release.xcconfig', 'SOURCE_ROOT'), 'Release.xcconfig'),
        (file_ref('Flutter/Generated.xcconfig', 'Generated.xcconfig', 'Flutter/Generated.xcconfig', 'SOURCE_ROOT'), 'Generated.xcconfig'),
    ]
    debug_xc, release_xc = flutter_children[0][0], flutter_children[1][0]
    app = oid('file', 'Runner.app')
    add('PBXFileReference', app,
        f'{app} /* Runner.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; '
        f'includeInIndex = 0; path = Runner.app; sourceTree = BUILT_PRODUCTS_DIR; }};')

    def group(key, name, children):
        ident = oid('group', key)
        kids = '\n'.join(f'\t\t\t\t{c} /* {n} */,' for c, n in children)
        add('PBXGroup', ident,
            f'{ident} /* {name} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{kids}\n\t\t\t);\n'
            f'\t\t\tname = {q(name)};\n\t\t\tsourceTree = "<group>";\n\t\t}};')
        return ident

    plugins = group('Plugins', 'Plugins', [(group('Plugins/' + k, k, v), k) for k, v in sorted(plugin_groups.items())])
    runner_group = group('Runner', 'Runner', runner_children + [(plugins, 'Plugins')])
    shared_group = group('Shared', 'Shared with iPhone', shared_children)
    flutter_group = group('Flutter', 'Flutter', flutter_children)
    products = group('Products', 'Products', [(app, 'Runner.app')])
    frameworks_children = []

    # ── build files and phases ──
    def build_files(items, phase):
        out = []
        for ref, name in items:
            ident = oid('build', phase, ref)
            add('PBXBuildFile', ident, f'{ident} /* {name} in {phase} */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};')
            out.append((ident, f'{name} in {phase}'))
        return out

    def phase(isa, name, files):
        ident = oid('phase', name)
        kids = '\n'.join(f'\t\t\t\t{c} /* {n} */,' for c, n in files)
        add(isa, ident,
            f'{ident} /* {name} */ = {{\n\t\t\tisa = {isa};\n\t\t\tbuildActionMask = 2147483647;\n'
            f'\t\t\tfiles = (\n{kids}\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')
        return ident

    sources_phase = phase('PBXSourcesBuildPhase', 'Sources', build_files(sources, 'Sources'))
    resources_phase = phase('PBXResourcesBuildPhase', 'Resources', build_files(resources, 'Resources'))
    mpv_ref = oid('package', 'mpv-build')
    mpvkit = oid('product', 'MPVKit')
    mpvkit_build = oid('build', 'Frameworks', 'MPVKit')
    add('PBXBuildFile', mpvkit_build, f'{mpvkit_build} /* MPVKit in Frameworks */ = {{isa = PBXBuildFile; productRef = {mpvkit} /* MPVKit */; }};')
    torrent_ref = oid('file', 'Frameworks/TorrServerKit.xcframework')
    add('PBXFileReference', torrent_ref,
        f'{torrent_ref} /* TorrServerKit.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; '
        f'name = TorrServerKit.xcframework; path = Frameworks/TorrServerKit.xcframework; sourceTree = SOURCE_ROOT; }};')
    frameworks_children.append((torrent_ref, 'TorrServerKit.xcframework'))
    torrent_build = oid('build', 'Frameworks', torrent_ref)
    add('PBXBuildFile', torrent_build, f'{torrent_build} /* TorrServerKit.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {torrent_ref} /* TorrServerKit.xcframework */; }};')
    # WebRTC (the voice call): a dynamic framework, linked and put inside the app
    # (tvos/scripts/fetch_webrtc.sh places its Apple TV slices in tvos/Frameworks)
    webrtc_ref = oid('file', 'Frameworks/WebRTC.xcframework')
    add('PBXFileReference', webrtc_ref,
        f'{webrtc_ref} /* WebRTC.xcframework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; '
        f'name = WebRTC.xcframework; path = Frameworks/WebRTC.xcframework; sourceTree = SOURCE_ROOT; }};')
    frameworks_children.append((webrtc_ref, 'WebRTC.xcframework'))
    webrtc_build = oid('build', 'Frameworks', webrtc_ref)
    add('PBXBuildFile', webrtc_build, f'{webrtc_build} /* WebRTC.xcframework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {webrtc_ref} /* WebRTC.xcframework */; }};')
    webrtc_embed = oid('build', 'Embed Frameworks', webrtc_ref)
    add('PBXBuildFile', webrtc_embed,
        f'{webrtc_embed} /* WebRTC.xcframework in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {webrtc_ref} /* WebRTC.xcframework */; '
        f'settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};')
    frameworks_phase = phase('PBXFrameworksBuildPhase', 'Frameworks',
                             [(mpvkit_build, 'MPVKit in Frameworks'), (torrent_build, 'TorrServerKit.xcframework in Frameworks'),
                              (webrtc_build, 'WebRTC.xcframework in Frameworks')])
    embed_phase = oid('phase', 'Embed Frameworks')
    add('PBXCopyFilesBuildPhase', embed_phase,
        f'{embed_phase} /* Embed Frameworks */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n'
        f'\t\t\tdstPath = "";\n\t\t\tdstSubfolderSpec = 10;\n\t\t\tfiles = (\n\t\t\t\t{webrtc_embed} /* WebRTC.xcframework in Embed Frameworks */,\n\t\t\t);\n'
        f'\t\t\tname = "Embed Frameworks";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};')

    def script(name, command, inputs=()):
        ident = oid('phase', name)
        paths = ''.join(f'\t\t\t\t{q(i)},\n' for i in inputs)
        add('PBXShellScriptBuildPhase', ident,
            f'{ident} /* {name} */ = {{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\talwaysOutOfDate = 1;\n'
            f'\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputPaths = (\n{paths}\t\t\t);\n'
            f'\t\t\tname = {q(name)};\n\t\t\toutputPaths = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
            f'\t\t\tshellPath = /bin/sh;\n\t\t\tshellScript = {q(command)};\n\t\t}};')
        return ident

    run_script = script('Run Script', '/bin/bash "$SOURCE_ROOT/scripts/xcode_appletv.sh" build\n')
    # (after Xcode has written the app's Info.plist, which it versions: named as its input, as
    # Flutter's own iPhone template does, or Xcode may run it first)
    thin_binary = script('Thin Binary', '/bin/bash "$SOURCE_ROOT/scripts/xcode_appletv.sh" sync_version\n',
                         inputs=('${TARGET_BUILD_DIR}/${INFOPLIST_PATH}',))

    # ── configurations ──
    common = {
        'ALWAYS_SEARCH_USER_PATHS': 'NO',
        'CLANG_ENABLE_MODULES': 'YES',
        'CLANG_ENABLE_OBJC_ARC': 'YES',
        'ENABLE_STRICT_OBJC_MSGSEND': 'YES',
        'GCC_NO_COMMON_BLOCKS': 'YES',
        'SDKROOT': 'appletvos',
        'SUPPORTED_PLATFORMS': 'appletvos appletvsimulator',
        'TARGETED_DEVICE_FAMILY': '3',
        'TVOS_DEPLOYMENT_TARGET': DEPLOYMENT,
    }
    project_configs = {
        'Debug': {**common, 'DEBUG_INFORMATION_FORMAT': 'dwarf', 'ENABLE_TESTABILITY': 'YES', 'GCC_OPTIMIZATION_LEVEL': '0',
                  'GCC_PREPROCESSOR_DEFINITIONS': ['DEBUG=1', '$(inherited)'], 'ONLY_ACTIVE_ARCH': 'YES', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone'},
        'Release': {**common, 'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym', 'ENABLE_NS_ASSERTIONS': 'NO',
                    'SWIFT_COMPILATION_MODE': 'wholemodule', 'SWIFT_OPTIMIZATION_LEVEL': '-O', 'VALIDATE_PRODUCT': 'YES'},
    }
    project_configs['Profile'] = dict(project_configs['Release'])
    target = {
        'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
        'CODE_SIGN_IDENTITY': 'Apple Development',
        'CODE_SIGN_STYLE': 'Automatic',
        'CURRENT_PROJECT_VERSION': '$(FLUTTER_BUILD_NUMBER)',
        'DEVELOPMENT_TEAM': '',
        'ENABLE_BITCODE': 'NO',
        # (the Run Script phase writes outside the build folder, under build/ of the repository)
        'ENABLE_USER_SCRIPT_SANDBOXING': 'NO',
        'FRAMEWORK_SEARCH_PATHS': ['$(inherited)', '$(PROJECT_DIR)/Flutter'],
        # (the copied plugins: flutter_webrtc's headers, C++ as its podspec builds it, and its
        # Objective-C for the Swift of both through one bridging header)
        'HEADER_SEARCH_PATHS': ['$(inherited)', '$(PROJECT_DIR)/Runner/Plugins/flutter_webrtc/include/flutter_webrtc', '$(PROJECT_DIR)/Runner/Plugins/flutter_webrtc/include'],
        'CLANG_CXX_LANGUAGE_STANDARD': 'c++14',
        'CLANG_CXX_LIBRARY': 'libc++',
        'SWIFT_OBJC_BRIDGING_HEADER': BRIDGING_HEADER,
        'INFOPLIST_FILE': 'Runner/Info.plist',
        'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks'],
        'LIBRARY_SEARCH_PATHS': ['$(inherited)', '$(PROJECT_DIR)/Flutter'],
        'MARKETING_VERSION': '$(FLUTTER_BUILD_NAME)',
        'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID,
        'PRODUCT_NAME': '$(TARGET_NAME)',
        'SWIFT_VERSION': '5.0',
        'TARGETED_DEVICE_FAMILY': '3',
        'TVOS_DEPLOYMENT_TARGET': DEPLOYMENT,
        'VERSIONING_SYSTEM': 'apple-generic',
    }
    target_configs = {
        'Debug': {**target, 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone'},
        'Release': dict(target),
        'Profile': dict(target),
    }

    def config_list(owner, configs, bases):
        ids = []
        for name in ('Debug', 'Release', 'Profile'):
            ident = oid('config', owner, name)
            base = bases.get(name)
            base_line = f'\t\t\tbaseConfigurationReference = {base[0]} /* {base[1]} */;\n' if base else ''
            add('XCBuildConfiguration', ident,
                f'{ident} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n{base_line}'
                f'\t\t\tbuildSettings = {{\n{build_settings(configs[name], chr(9) * 4)}\n\t\t\t}};\n'
                f'\t\t\tname = {name};\n\t\t}};')
            ids.append((ident, name))
        ident = oid('configlist', owner)
        kids = '\n'.join(f'\t\t\t\t{c} /* {n} */,' for c, n in ids)
        add('XCConfigurationList', ident,
            f'{ident} /* Build configuration list for {owner} */ = {{\n\t\t\tisa = XCConfigurationList;\n'
            f'\t\t\tbuildConfigurations = (\n{kids}\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n'
            f'\t\t\tdefaultConfigurationName = Release;\n\t\t}};')
        return ident

    project_list = config_list('PBXProject "Runner"', project_configs, {})
    target_list = config_list('PBXNativeTarget "Runner"', target_configs,
                              {'Debug': (debug_xc, 'Debug.xcconfig'), 'Release': (release_xc, 'Release.xcconfig'), 'Profile': (release_xc, 'Release.xcconfig')})

    runner = oid('target', 'Runner')
    phases = [(run_script, 'Run Script'), (sources_phase, 'Sources'), (frameworks_phase, 'Frameworks'),
              (resources_phase, 'Resources'), (embed_phase, 'Embed Frameworks'), (thin_binary, 'Thin Binary')]
    kids = '\n'.join(f'\t\t\t\t{c} /* {n} */,' for c, n in phases)
    add('PBXNativeTarget', runner,
        f'{runner} /* Runner */ = {{\n\t\t\tisa = PBXNativeTarget;\n'
        f'\t\t\tbuildConfigurationList = {target_list} /* Build configuration list for PBXNativeTarget "Runner" */;\n'
        f'\t\t\tbuildPhases = (\n{kids}\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n'
        f'\t\t\tname = Runner;\n\t\t\tpackageProductDependencies = (\n\t\t\t\t{mpvkit} /* MPVKit */,\n\t\t\t);\n'
        f'\t\t\tproductName = Runner;\n\t\t\tproductReference = {app} /* Runner.app */;\n'
        f'\t\t\tproductType = "com.apple.product-type.application";\n\t\t}};')

    add('XCRemoteSwiftPackageReference', mpv_ref,
        f'{mpv_ref} /* XCRemoteSwiftPackageReference "mpv-build" */ = {{\n\t\t\tisa = XCRemoteSwiftPackageReference;\n'
        f'\t\t\trepositoryURL = {q(url)};\n\t\t\trequirement = {{\n\t\t\t\tkind = revision;\n\t\t\t\trevision = {revision};\n\t\t\t}};\n\t\t}};')
    add('XCSwiftPackageProductDependency', mpvkit,
        f'{mpvkit} /* MPVKit */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n'
        f'\t\t\tpackage = {mpv_ref} /* XCRemoteSwiftPackageReference "mpv-build" */;\n\t\t\tproductName = MPVKit;\n\t\t}};')

    frameworks_group = group('Frameworks', 'Frameworks', frameworks_children)
    main_group = oid('group', 'main')
    kids = '\n'.join(f'\t\t\t\t{c} /* {n} */,' for c, n in [(flutter_group, 'Flutter'), (runner_group, 'Runner'), (shared_group, 'Shared with iPhone'), (frameworks_group, 'Frameworks'), (products, 'Products')])
    add('PBXGroup', main_group,
        f'{main_group} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n{kids}\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};')

    project = oid('project')
    add('PBXProject', project,
        f'{project} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tLastUpgradeCheck = 1600;\n'
        f'\t\t\t\tORGANIZATIONNAME = "";\n\t\t\t\tTargetAttributes = {{\n\t\t\t\t\t{runner} = {{\n'
        f'\t\t\t\t\t\tCreatedOnToolsVersion = 7.3.1;\n\t\t\t\t\t\tLastSwiftMigration = 1100;\n\t\t\t\t\t}};\n\t\t\t\t}};\n\t\t\t}};\n'
        f'\t\t\tbuildConfigurationList = {project_list} /* Build configuration list for PBXProject "Runner" */;\n'
        f'\t\t\tcompatibilityVersion = "Xcode 9.3";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n'
        f'\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {main_group};\n'
        f'\t\t\tpackageReferences = (\n\t\t\t\t{mpv_ref} /* XCRemoteSwiftPackageReference "mpv-build" */,\n\t\t\t);\n'
        f'\t\t\tproductRefGroup = {products} /* Products */;\n\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n'
        f'\t\t\ttargets = (\n\t\t\t\t{runner} /* Runner */,\n\t\t\t);\n\t\t}};')

    out = ['// !$*UTF8*$!', '{', '\tarchiveVersion = 1;', '\tclasses = {', '\t};', '\tobjectVersion = 54;', '\tobjects = {', '']
    for section in sorted(objects):
        out.append(f'/* Begin {section} section */')
        for _, text in sorted(objects[section]):
            out.append('\t\t' + text)
        out.append(f'/* End {section} section */')
        out.append('')
    out += ['\t};', f'\trootObject = {project} /* Project object */;', '}', '']

    proj = TVOS / 'Runner.xcodeproj'
    write(proj / 'project.pbxproj', '\n'.join(out))
    write(proj / 'project.xcworkspace' / 'contents.xcworkspacedata', WORKSPACE.format(location='self:'))
    write(TVOS / 'Runner.xcworkspace' / 'contents.xcworkspacedata', WORKSPACE.format(location='group:Runner.xcodeproj'))
    for root in (proj / 'project.xcworkspace', TVOS / 'Runner.xcworkspace'):
        write(root / 'xcshareddata' / 'IDEWorkspaceChecks.plist', CHECKS)
        write(root / 'xcshareddata' / 'swiftpm' / 'Package.resolved', RESOLVED.format(url=url, revision=revision))
    write(proj / 'xcshareddata' / 'xcschemes' / 'Runner.xcscheme', SCHEME.format(runner=runner))
    # every file the project names is there
    for rel in RUNNER_SOURCES + RESOURCES + ['Info.plist'] + tree_sources():
        assert (TVOS / 'Runner' / rel).exists(), rel
    assert (TVOS / BRIDGING_HEADER).exists(), BRIDGING_HEADER
    for rel in SHARED_SOURCES:
        assert (REPO / rel).exists(), rel
    print(f'wrote {proj.relative_to(REPO)} ({len(sources)} source files, mpv-build {revision[:12]})')


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8', newline='\n')


WORKSPACE = '''<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "{location}">
   </FileRef>
</Workspace>
'''

CHECKS = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>IDEDidComputeMac32BitWarning</key>
	<true/>
</dict>
</plist>
'''

RESOLVED = '''{{
  "pins" : [
    {{
      "identity" : "mpv-build",
      "kind" : "remoteSourceControl",
      "location" : "{url}",
      "state" : {{
        "revision" : "{revision}"
      }}
    }}
  ],
  "version" : 2
}}
'''

SCHEME = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.3">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{runner}"
               BuildableName = "Runner.app"
               BlueprintName = "Runner"
               ReferencedContainer = "container:Runner.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{runner}"
            BuildableName = "Runner.app"
            BlueprintName = "Runner"
            ReferencedContainer = "container:Runner.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Profile"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{runner}"
            BuildableName = "Runner.app"
            BlueprintName = "Runner"
            ReferencedContainer = "container:Runner.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''

if __name__ == '__main__':
    main()
