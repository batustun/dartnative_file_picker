Pod::Spec.new do |s|
  s.name             = 'dartnative_file_picker'
  s.version          = '0.1.0'
  s.summary          = 'Native document picker for DartNative (UIDocumentPickerViewController).'
  s.description      = <<-DESC
    Document picker for DartNative apps. Presents UIDocumentPickerViewController
    with UniformTypeIdentifiers content types, handles security-scoped resource
    access and security-scoped bookmarks, and streams document bytes to Dart
    over a pure FFI @_cdecl bridge, with zero Flutter platform channels.
  DESC
  s.homepage         = 'https://github.com/batustun/dartnative_file_picker'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Batuhan Ustun' => 'https://github.com/batustun' }

  # 15.0 is what `dn plugin build` compiles pods against ("the lowest version
  # current Xcode accepts") and it warns if the podspec disagrees. Comfortably
  # above the 14.0 that UniformTypeIdentifiers and the modern
  # UIDocumentPickerViewController(forOpeningContentTypes:asCopy:) initializer
  # need, so no availability guards are required.
  s.platform         = :ios, '15.0'

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'

  # UniformTypeIdentifiers for UTType, MobileCoreServices is not used.
  s.frameworks       = 'UIKit', 'Foundation', 'UniformTypeIdentifiers'

  s.swift_version    = '5.9'

  s.pod_target_xcconfig = {
    # Required for Swift module visibility.
    'DEFINES_MODULE' => 'YES',
  }
end
