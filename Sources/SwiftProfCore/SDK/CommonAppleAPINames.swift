import Foundation

/// Curated list of well-known Apple API identifiers that are NOT discoverable via
/// `.swiftinterface` parsing — they originate in Objective-C headers (UIImagePickerController,
/// AVCaptureDevice, PHPickerConfiguration, etc.) which our SwiftSyntax-based loader cannot
/// reach. We use these as additional shielding in `RollbackPass`: when a name from this set
/// appears in user output, it's assumed to be a call to Apple's API, not a desynced rename.
///
/// Keep focused. Adding too many names risks false-negatives during rollback (real desyncs of
/// these names won't be caught). The names below are deliberately high-collision Apple API
/// identifiers that frequently appear at call sites of ObjC-rooted frameworks.
public enum CommonAppleAPINames {
    public static let names: Set<String> = [
        // AVCaptureDevice.AuthorizationStatus / PHAuthorizationStatus / CLAuthorizationStatus /
        // UNAuthorizationStatus
        "authorized", "denied", "notDetermined", "restricted", "limited",
        "provisional", "ephemeral", "authorizedAlways", "authorizedWhenInUse",

        // UIImagePickerController family
        "camera", "photoLibrary", "savedPhotosAlbum", "allowsEditing",
        "compressionQuality", "cameraDevice", "front", "rear",
        "mediaTypes", "showsCameraControls", "cameraOverlayView",

        // PHPickerConfiguration / PHPhotoLibrary
        "selectionLimit", "filter", "preferredAssetRepresentationMode",

        // UIInterfaceOrientation / UIDeviceOrientation
        "portrait", "landscapeLeft", "landscapeRight", "portraitUpsideDown",
        "faceUp", "faceDown",

        // UIBackgroundFetchResult / UIBackgroundRefreshStatus
        "noData", "newData", "failed",

        // UIActivityIndicator / UIViewContentMode
        "scaleToFill", "scaleAspectFit", "scaleAspectFill", "redraw",
        "topLeft", "topRight", "bottomLeft", "bottomRight",

        // CALayer / UIView frequently-seen members
        "cornerRadius", "borderWidth", "borderColor", "masksToBounds",
        "shadowColor", "shadowOpacity", "shadowOffset", "shadowRadius",
        "contents", "contentsScale",

        // Layout properties used everywhere
        "frame", "bounds", "center", "origin", "size", "width", "height",
        "x", "y", "transform", "alpha", "isHidden", "isEnabled",
        "isUserInteractionEnabled", "backgroundColor", "tintColor",
        "contentMode", "clipsToBounds", "autoresizingMask",

        // UILabel / UITextField / UITextView
        "text", "attributedText", "font", "textColor", "textAlignment",
        "numberOfLines", "lineBreakMode", "placeholder", "isSecureTextEntry",
        "keyboardType", "autocapitalizationType", "autocorrectionType",
        "returnKeyType", "delegate", "dataSource",

        // UINavigationController / UIViewController
        "title", "navigationItem", "navigationBar", "tabBarItem",
        "presentingViewController", "presentedViewController",
        "modalPresentationStyle", "modalTransitionStyle",
        "viewDidLoad", "viewWillAppear", "viewDidAppear",
        "viewWillDisappear", "viewDidDisappear",

        // Common delegate callbacks
        "didFinishPickingMediaWithInfo", "imagePickerControllerDidCancel",
        "didReceiveMemoryWarning", "applicationDidEnterBackground",

        // Common NSNotification / NSObject names
        "default", "current", "shared", "main", "object", "userInfo",
        "post", "addObserver", "removeObserver",

        // Foundation common
        "data", "string", "value", "key", "name", "description",
        "count", "isEmpty", "first", "last",

        // SwiftUI accent / color / style
        "primary", "secondary", "accentColor", "systemGroupedBackground",
        "label", "auto", "none", "system", "monospaced",

        // Layout alignment
        "leading", "trailing", "top", "bottom",
    ]
}
