#!/usr/bin/env python3
"""Add the QulexWidget WidgetKit extension to ios/Runner.xcodeproj.

WHY A SCRIPT
------------
Adding a target is normally three clicks in Xcode. There is no Mac here, and
project.pbxproj is a graph of UUID-keyed objects where a hand edit that looks
fine can fail the build in ways the log does not explain. A script is
reviewable, repeatable, and can be validated by re-parsing the result before
anyone spends a build on it.

Idempotent: running it twice is a no-op.

WHAT IT ADDS
------------
  * PBXNativeTarget "QulexWidget" (com.apple.product-type.app-extension)
  * Sources / Frameworks / Resources phases for it
  * An "Embed App Extensions" copy phase on Runner, so the .appex ships
  * A target dependency, so Runner builds the widget first
  * CODE_SIGN_ENTITLEMENTS on Runner and on the widget, both pointing at
    entitlements files that declare App Group group.com.codeascent.qbit -
    which is what lets the widget read what the app writes
"""
import re, sys
from pathlib import Path

PBX = Path(sys.argv[1] if len(sys.argv) > 1 else "ios/Runner.xcodeproj/project.pbxproj")
BUNDLE = "com.codeascent.qbit"
NAME = "QulexWidget"

# Deterministic ids so a re-run produces an identical file.
U = {k: f"AA{i:022X}" for i, k in enumerate([
    "target", "appex", "swift_ref", "plist_ref", "ent_ref", "group",
    "sources", "frameworks", "resources", "bf_swift", "embed", "bf_appex",
    "cfglist", "cfg_debug", "cfg_release", "cfg_profile", "dep", "proxy",
], 1)}

def section(src, name, block):
    """Insert `block` at the top of a Begin/End section, creating it if absent."""
    begin = f"/* Begin {name} section */"
    if begin in src:
        return src.replace(begin, begin + "\n" + block, 1)
    # create the section just before PBXProject, keeping file order sane
    anchor = "/* Begin PBXProject section */"
    return src.replace(anchor,
        f"/* Begin {name} section */\n{block}\n/* End {name} section */\n\n" + anchor, 1)

def main():
    s = PBX.read_text(encoding="utf-8")
    if NAME in s:
        print("QulexWidget already present in the project — nothing to do.")
        return 0
    orig_len = len(s)

    s = section(s, "PBXBuildFile", f"""\t\t{U['bf_swift']} /* {NAME}.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {U['swift_ref']} /* {NAME}.swift */; }};
\t\t{U['bf_appex']} /* {NAME}.appex in Embed App Extensions */ = {{isa = PBXBuildFile; fileRef = {U['appex']} /* {NAME}.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};""")

    s = section(s, "PBXFileReference", f"""\t\t{U['appex']} /* {NAME}.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = {NAME}.appex; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{U['swift_ref']} /* {NAME}.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {NAME}.swift; sourceTree = "<group>"; }};
\t\t{U['plist_ref']} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
\t\t{U['ent_ref']} /* {NAME}.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = {NAME}.entitlements; sourceTree = "<group>"; }};""")

    s = section(s, "PBXGroup", f"""\t\t{U['group']} /* {NAME} */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{U['swift_ref']} /* {NAME}.swift */,
\t\t\t\t{U['plist_ref']} /* Info.plist */,
\t\t\t\t{U['ent_ref']} /* {NAME}.entitlements */,
\t\t\t);
\t\t\tpath = {NAME};
\t\t\tsourceTree = "<group>";
\t\t}};""")

    s = section(s, "PBXSourcesBuildPhase", f"""\t\t{U['sources']} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{U['bf_swift']} /* {NAME}.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};""")

    s = section(s, "PBXFrameworksBuildPhase", f"""\t\t{U['frameworks']} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};""")

    s = section(s, "PBXResourcesBuildPhase", f"""\t\t{U['resources']} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};""")

    s = section(s, "PBXCopyFilesBuildPhase", f"""\t\t{U['embed']} /* Embed App Extensions */ = {{
\t\t\tisa = PBXCopyFilesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tdstPath = "";
\t\t\tdstSubfolderSpec = 13;
\t\t\tfiles = (
\t\t\t\t{U['bf_appex']} /* {NAME}.appex in Embed App Extensions */,
\t\t\t);
\t\t\tname = "Embed App Extensions";
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};""")

    s = section(s, "PBXContainerItemProxy", f"""\t\t{U['proxy']} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = 97C146E61CF9000F007C117D /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {U['target']};
\t\t\tremoteInfo = {NAME};
\t\t}};""")

    s = section(s, "PBXTargetDependency", f"""\t\t{U['dep']} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {U['target']} /* {NAME} */;
\t\t\ttargetProxy = {U['proxy']} /* PBXContainerItemProxy */;
\t\t}};""")

    s = section(s, "PBXNativeTarget", f"""\t\t{U['target']} /* {NAME} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {U['cfglist']} /* Build configuration list for PBXNativeTarget "{NAME}" */;
\t\t\tbuildPhases = (
\t\t\t\t{U['sources']} /* Sources */,
\t\t\t\t{U['frameworks']} /* Frameworks */,
\t\t\t\t{U['resources']} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = {NAME};
\t\t\tproductName = {NAME};
\t\t\tproductReference = {U['appex']} /* {NAME}.appex */;
\t\t\tproductType = "com.apple.product-type.app-extension";
\t\t}};""")

    common = (f'\t\t\t\tCLANG_ENABLE_MODULES = YES;\n'
              f'\t\t\t\tCODE_SIGN_ENTITLEMENTS = {NAME}/{NAME}.entitlements;\n'
              f'\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
              f'\t\t\t\tCURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)";\n'
              f'\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n'
              f'\t\t\t\tINFOPLIST_FILE = {NAME}/Info.plist;\n'
              f'\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = Qulex;\n'
              f'\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";\n'
              f'\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;\n'
              f'\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n'
              f'\t\t\t\t\t"$(inherited)",\n'
              f'\t\t\t\t\t"@executable_path/Frameworks",\n'
              f'\t\t\t\t\t"@executable_path/../../Frameworks",\n'
              f'\t\t\t\t);\n'
              f'\t\t\t\tMARKETING_VERSION = "$(FLUTTER_BUILD_NAME)";\n'
              f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE}.{NAME};\n'
              f'\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n'
              f'\t\t\t\tSKIP_INSTALL = YES;\n'
              f'\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n'
              f'\t\t\t\tSWIFT_VERSION = 5.0;\n'
              f'\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n')
    cfgs = []
    for key, name, extra in (("cfg_debug", "Debug", '\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";\n'),
                             ("cfg_release", "Release", ""),
                             ("cfg_profile", "Profile", "")):
        cfgs.append(f"""\t\t{U[key]} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{common}{extra}\t\t\t}};
\t\t\tname = {name};
\t\t}};""")
    s = section(s, "XCBuildConfiguration", "\n".join(cfgs))

    s = section(s, "XCConfigurationList", f"""\t\t{U['cfglist']} /* Build configuration list for PBXNativeTarget "{NAME}" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{U['cfg_debug']} /* Debug */,
\t\t\t\t{U['cfg_release']} /* Release */,
\t\t\t\t{U['cfg_profile']} /* Profile */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};""")

    # --- wire it into the existing graph ---------------------------------
    s = s.replace("\t\t\t\t331C8080294A63A400263BE5 /* RunnerTests */,\n\t\t\t);",
                  f"\t\t\t\t331C8080294A63A400263BE5 /* RunnerTests */,\n\t\t\t\t{U['target']} /* {NAME} */,\n\t\t\t);", 1)
    s = s.replace("\t\t\t\t331C8081294A63A400263BE5 /* RunnerTests.xctest */,\n\t\t\t);",
                  f"\t\t\t\t331C8081294A63A400263BE5 /* RunnerTests.xctest */,\n\t\t\t\t{U['appex']} /* {NAME}.appex */,\n\t\t\t);", 1)
    # widget group under the project root
    s = s.replace("\t\t\t\t97C146EF1CF9000F007C117D /* Products */,",
                  f"\t\t\t\t{U['group']} /* {NAME} */,\n\t\t\t\t97C146EF1CF9000F007C117D /* Products */,", 1)
    # embed phase + dependency on Runner
    s = s.replace("\t\t\t\t3B06AD1E1E4923F5004D2608 /* Thin Binary */,\n\t\t\t);",
                  f"\t\t\t\t3B06AD1E1E4923F5004D2608 /* Thin Binary */,\n\t\t\t\t{U['embed']} /* Embed App Extensions */,\n\t\t\t);", 1)
    s = re.sub(r'(/\* Runner \*/ = \{\s*\n\s*isa = PBXNativeTarget;(?:.|\n)*?dependencies = \(\n)(\s*\);)',
               lambda m: m.group(1) + f"\t\t\t\t{U['dep']} /* PBXTargetDependency */,\n" + m.group(2), s, count=1)
    # Runner needs the App Group entitlement too, in every configuration
    s = re.sub(r'(PRODUCT_BUNDLE_IDENTIFIER = com\.codeascent\.qbit;)',
               r'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;\n\t\t\t\t\1', s)

    if len(s) <= orig_len:
        print("ERROR: nothing was inserted", file=sys.stderr); return 1
    PBX.write_text(s, encoding="utf-8")
    print(f"added {NAME}: {orig_len:,} -> {len(s):,} bytes")
    return 0

if __name__ == "__main__":
    sys.exit(main())
