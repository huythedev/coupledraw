#!/usr/bin/env python3
"""Generate a conventional Xcode project without external dependencies.

The generated pbxproj is intentionally small and uses explicit source references.
Run this script after adding another Swift file to Sources or Tests.
"""
from __future__ import annotations

import hashlib
import argparse
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description="Generate CoupleDraw Xcode project")
parser.add_argument("--enable-push", action="store_true",
                    help="Include APNs entitlements; requires an Apple Developer team with Push Notifications")
args = parser.parse_args()
PUSH_ENABLED = args.enable_push
PROJECT = ROOT / "CoupleDraw.xcodeproj"
SOURCES = sorted((ROOT / "Sources").glob("*.swift"))
TESTS = sorted((ROOT / "Tests").glob("*.swift"))
WIDGET_SOURCES = sorted((ROOT / "Widget").glob("*.swift"))


def oid(name: str) -> str:
    return hashlib.sha1(name.encode("utf-8")).hexdigest()[:24].upper()


def quoted(s: str) -> str:
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


objects: dict[str, str] = {}


def add(name: str, body: str) -> str:
    ident = oid(name)
    assert ident not in objects
    objects[ident] = f"\t\t{ident} /* {name} */ = {{ {body} }};"
    return ident


def ref(name: str) -> str:
    return f"{oid(name)} /* {name} */"


for f in SOURCES + TESTS + WIDGET_SOURCES:
    add(f"ref:{f.name}", f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(f.name)}; sourceTree = \"<group>\";")
    add(f"build:{f.name}", f"isa = PBXBuildFile; fileRef = {ref('ref:' + f.name)};")

add("Info.plist", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
add("WidgetInfo.plist", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = WidgetInfo.plist; sourceTree = "<group>";')
for name in ("PushDevelopment.entitlements", "PushProduction.entitlements"):
    add(name, f'isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = {name}; sourceTree = "<group>";')
add("README.md", 'isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = README.md; sourceTree = "<group>";')
add("ref:Assets.xcassets", 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
add("build:Assets.xcassets", f'isa = PBXBuildFile; fileRef = {ref("ref:Assets.xcassets")};')
add("product:app", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = CoupleDraw.app; sourceTree = BUILT_PRODUCTS_DIR;')
add("product:tests", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = CoupleDrawTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
add("product:widget", 'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = CoupleDrawWidget.appex; sourceTree = BUILT_PRODUCTS_DIR;')
add("embed:widget", f'isa = PBXBuildFile; fileRef = {ref("product:widget")}; settings = {{ ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }};')


def group(name: str, children: list[str], path: str | None = None) -> None:
    entries = ', '.join(ref(child) for child in children)
    path_part = f"path = {quoted(path)}; " if path else ""
    add(name, f'isa = PBXGroup; children = ({entries}, ); {path_part}sourceTree = "<group>";')


group("group:Sources", ["ref:" + f.name for f in SOURCES], "Sources")
group("group:Tests", ["ref:" + f.name for f in TESTS], "Tests")
group("group:Widget", ["ref:" + f.name for f in WIDGET_SOURCES], "Widget")
group("group:Assets", ["ref:Assets.xcassets"])
group("group:Config", ["Info.plist", "WidgetInfo.plist", "PushDevelopment.entitlements", "PushProduction.entitlements"], "Config")
group("group:Products", ["product:app", "product:tests", "product:widget"])
group("group:root", ["group:Sources", "group:Assets", "group:Widget", "group:Tests", "group:Config", "README.md", "group:Products"])


def phase(name: str, isa: str, files: list[str]) -> None:
    entries = ', '.join(ref(f) for f in files)
    array = f"{entries}, " if entries else ""
    add(name, f"isa = {isa}; buildActionMask = 2147483647; files = ({array}); runOnlyForDeploymentPostprocessing = 0;")


phase("phase:app:sources", "PBXSourcesBuildPhase", ["build:" + f.name for f in SOURCES])
phase("phase:tests:sources", "PBXSourcesBuildPhase", ["build:" + f.name for f in TESTS])
phase("phase:widget:sources", "PBXSourcesBuildPhase", ["build:" + f.name for f in WIDGET_SOURCES])
for target in ("app", "tests", "widget"):
    phase(f"phase:{target}:frameworks", "PBXFrameworksBuildPhase", [])
    phase(f"phase:{target}:resources", "PBXResourcesBuildPhase", ["build:Assets.xcassets"] if target == "app" else [])
add("phase:app:embed", f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = ({ref("embed:widget")}, ); name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')

add("proxy:tests", f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {oid("target:app")}; remoteInfo = CoupleDraw;')
add("dependency:tests", f'isa = PBXTargetDependency; target = {ref("target:app")}; targetProxy = {ref("proxy:tests")};')
add("proxy:widget", f'isa = PBXContainerItemProxy; containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {oid("target:widget")}; remoteInfo = CoupleDrawWidget;')
add("dependency:widget", f'isa = PBXTargetDependency; target = {ref("target:widget")}; targetProxy = {ref("proxy:widget")};')

for target, product, dependencies in (("app", "app", ref("dependency:widget")),
                                      ("tests", "tests", ref("dependency:tests")),
                                      ("widget", "widget", "")):
    kinds = ("sources", "frameworks", "resources", "embed") if target == "app" else ("sources", "frameworks", "resources")
    phases = ', '.join(ref(f"phase:{target}:{kind}") for kind in kinds)
    dep_array = f"{dependencies}, " if dependencies else ""
    name = {"app": "CoupleDraw", "tests": "CoupleDrawTests", "widget": "CoupleDrawWidget"}[target]
    product_type = {"app": "com.apple.product-type.application", "tests": "com.apple.product-type.bundle.unit-test", "widget": "com.apple.product-type.app-extension"}[target]
    add(f"target:{target}", f'isa = PBXNativeTarget; buildConfigurationList = {ref("configlist:" + target)}; buildPhases = ({phases}, ); buildRules = (); dependencies = ({dep_array}); name = {name}; productName = {name}; productReference = {ref("product:" + product)}; productType = {quoted(product_type)};')

project_settings = {
    "CLANG_ENABLE_MODULES": "YES",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "SDKROOT": "iphoneos",
    "SWIFT_VERSION": "5.0",
    "TARGETED_DEVICE_FAMILY": '"1"',
}
app_settings = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "NO",
    "CODE_SIGN_STYLE": "Automatic",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "Config/Info.plist",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.example.CoupleDraw",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}
test_settings = {
    "CODE_SIGN_STYLE": "Automatic",
    "GENERATE_INFOPLIST_FILE": "YES",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.example.CoupleDrawTests",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "TEST_HOST": '"$(BUILT_PRODUCTS_DIR)/CoupleDraw.app/CoupleDraw"',
    "BUNDLE_LOADER": '"$(TEST_HOST)"',
}
widget_settings = {
    "APPLICATION_EXTENSION_API_ONLY": "YES",
    "CODE_SIGN_STYLE": "Automatic",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": "Config/WidgetInfo.plist",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.example.CoupleDraw.Widget",
    "PRODUCT_NAME": '"$(TARGET_NAME)"',
    "SKIP_INSTALL": "YES",
    "SUPPORTED_PLATFORMS": '"iphoneos iphonesimulator"',
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}


def setting_text(settings: dict[str, str]) -> str:
    return " ".join(f"{key} = {value};" for key, value in settings.items())


for target, base in (("project", project_settings), ("app", app_settings), ("tests", test_settings), ("widget", widget_settings)):
    for mode in ("Debug", "Release"):
        settings = dict(base)
        if target == "project":
            settings["SWIFT_OPTIMIZATION_LEVEL"] = '"-Onone"' if mode == "Debug" else '"-O"'
            settings["DEBUG_INFORMATION_FORMAT"] = "dwarf" if mode == "Debug" else '"dwarf-with-dsym"'
        if target == "app" and mode == "Debug":
            settings["ENABLE_TESTABILITY"] = "YES"
        if target == "app" and PUSH_ENABLED:
            settings["CODE_SIGN_ENTITLEMENTS"] = "Config/PushDevelopment.entitlements" if mode == "Debug" else "Config/PushProduction.entitlements"
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = '"PUSH_ENABLED"'
        add(f"config:{target}:{mode}", f'isa = XCBuildConfiguration; buildSettings = {{ {setting_text(settings)} }}; name = {mode};')
    add(f"configlist:{target}", f'isa = XCConfigurationList; buildConfigurations = ({ref("config:" + target + ":Debug")}, {ref("config:" + target + ":Release")}, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

push_capability = 'SystemCapabilities = { com.apple.Push = { enabled = 1; }; }; ' if PUSH_ENABLED else ''
add("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 1600; TargetAttributes = {{ {oid("target:app")} = {{ CreatedOnToolsVersion = 16.0; ProvisioningStyle = Automatic; {push_capability}}}; {oid("target:tests")} = {{ CreatedOnToolsVersion = 16.0; ProvisioningStyle = Automatic; TestTargetID = {oid("target:app")}; }}; {oid("target:widget")} = {{ CreatedOnToolsVersion = 16.0; ProvisioningStyle = Automatic; }}; }}; }}; buildConfigurationList = {ref("configlist:project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = {ref("group:root")}; productRefGroup = {ref("group:Products")}; projectDirPath = ""; projectRoot = ""; targets = ({ref("target:app")}, {ref("target:tests")}, {ref("target:widget")}, );')

PROJECT.mkdir(exist_ok=True)
pbx = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n"
pbx += "\n".join(objects[key] for key in sorted(objects))
pbx += f"\n\t}};\n\trootObject = {ref('project')};\n}}\n"
(PROJECT / "project.pbxproj").write_text(pbx)

schemes = PROJECT / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
app_id = oid("target:app")
test_id = oid("target:tests")
(schemes / "CoupleDraw.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="CoupleDraw.app" BlueprintName="CoupleDraw" ReferencedContainer="container:CoupleDraw.xcodeproj"/>
    </BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.Posix" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_id}" BuildableName="CoupleDrawTests.xctest" BlueprintName="CoupleDrawTests" ReferencedContainer="container:CoupleDraw.xcodeproj"/></TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.Posix" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="CoupleDraw.app" BlueprintName="CoupleDraw" ReferencedContainer="container:CoupleDraw.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="CoupleDraw.app" BlueprintName="CoupleDraw" ReferencedContainer="container:CoupleDraw.xcodeproj"/></BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated {PROJECT / 'project.pbxproj'} with {len(SOURCES)} app sources, {len(WIDGET_SOURCES)} widget sources, and {len(TESTS)} test sources")
