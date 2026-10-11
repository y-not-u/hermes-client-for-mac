#!/usr/bin/env python3
"""Generate the dependency-free Xcode project from checked-in Swift sources."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parent.parent
uid = lambda s: hashlib.sha1(s.encode()).hexdigest()[:24].upper()
files = sorted((root/'HermesMac').rglob('*.swift'))
objects = []
def obj(name, body):
    objects.append(f'{uid(name)} = {{ {body} }};')
for file in files:
    p = str(file.relative_to(root))
    obj(p, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{p}"; sourceTree = "<group>";')
    obj(p+'build', f'isa = PBXBuildFile; fileRef = {uid(p)};')
obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = HermesMac.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('products', f'isa = PBXGroup; children = ({uid("product")}); name = Products; sourceTree = "<group>";')
obj('root', f'isa = PBXGroup; children = ({",".join(uid(str(f.relative_to(root))) for f in files)},{uid("products")}); sourceTree = "<group>";')
obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(uid(str(f.relative_to(root))+"build") for f in files)}); runOnlyForDeploymentPostprocessing = 0;')
obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj('resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
for kind in ['project','target']:
    for config in ['Debug','Release']:
        settings = 'MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; '
        if kind == 'target':
            settings += 'PRODUCT_NAME = HermesMac; PRODUCT_BUNDLE_IDENTIFIER = com.hermes.mac; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_FILE = HermesMac/Info.plist; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.productivity"; CODE_SIGN_STYLE = Automatic; ENABLE_HARDENED_RUNTIME = YES; '
        settings += 'SWIFT_OPTIMIZATION_LEVEL = "'+('-Onone' if config == 'Debug' else '-O')+'";'
        obj(kind+config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ {settings} }};')
    obj(kind+'configs', f'isa = XCConfigurationList; buildConfigurations = ({uid(kind+"Debug")},{uid(kind+"Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target', f'isa = PBXNativeTarget; buildConfigurationList = {uid("targetconfigs")}; buildPhases = ({uid("sources")},{uid("frameworks")},{uid("resources")}); buildRules = (); dependencies = (); name = HermesMac; productName = HermesMac; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1630; }}; buildConfigurationList = {uid("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {uid("root")}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = ({uid("target")});')
(root/'HermesMac.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {uid("project")}; }}\n')
(root/'HermesMac.xcodeproj/xcshareddata/xcschemes/HermesMac.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="HermesMac.app" BlueprintName="HermesMac" ReferencedContainer="container:HermesMac.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="HermesMac.app" BlueprintName="HermesMac" ReferencedContainer="container:HermesMac.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
