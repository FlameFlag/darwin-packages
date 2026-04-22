{ version }:
{
  CFBundleDevelopmentRegion = "en";
  CFBundleExecutable = "ghostty";
  CFBundleIdentifier = "com.mitchellh.ghostty";
  CFBundleInfoDictionaryVersion = "6.0";
  CFBundleName = "Ghostty";
  CFBundlePackageType = "APPL";
  CFBundleShortVersionString = version;
  CFBundleVersion = "1";
  CFBundleIconName = "AppIconImage";
  LSApplicationCategoryType = "public.app-category.developer-tools";
  LSMinimumSystemVersion = "13.0";
  NSHighResolutionCapable = true;
  NSAppleScriptEnabled = true;
  OSAScriptingDefinition = "Ghostty.sdef";
  NSPrincipalClass = "NSApplication";
  NSMainNibFile = "MainMenu";
  NSDockTilePlugIn = "DockTilePlugin.plugin";
  CFBundleDocumentTypes = [
    {
      CFBundleTypeExtensions = [
        "command"
        "tool"
        "sh"
        "zsh"
        "csh"
        "pl"
      ];
      CFBundleTypeIconFile = "AppIcon.icns";
      CFBundleTypeName = "Terminal scripts";
      CFBundleTypeRole = "Editor";
    }
    {
      CFBundleTypeName = "Folders";
      CFBundleTypeRole = "Editor";
      LSHandlerRank = "Alternate";
      LSItemContentTypes = [ "public.directory" ];
    }
    {
      CFBundleTypeRole = "Shell";
      LSItemContentTypes = [ "public.unix-executable" ];
    }
  ];
  LSEnvironment = {
    GHOSTTY_MAC_LAUNCH_SOURCE = "app";
  };
  MDItemKeywords = "Terminal";
  NSServices = [
    {
      NSMenuItem = {
        default = "New Ghostty Tab Here";
      };
      NSMessage = "openTab";
      NSRequiredContext = {
        NSTextContent = "FilePath";
      };
      NSSendTypes = [
        "NSFilenamesPboardType"
        "public.plain-text"
      ];
    }
    {
      NSMenuItem = {
        default = "New Ghostty Window Here";
      };
      NSMessage = "openWindow";
      NSRequiredContext = {
        NSTextContent = "FilePath";
      };
      NSSendTypes = [
        "NSFilenamesPboardType"
        "public.plain-text"
      ];
    }
  ];
  UTExportedTypeDeclarations = [
    {
      UTTypeIdentifier = "com.mitchellh.ghosttySurfaceId";
      UTTypeDescription = "Ghostty Surface Identifier";
      UTTypeConformsTo = [ "public.data" ];
      UTTypeTagSpecification = { };
    }
  ];
}
