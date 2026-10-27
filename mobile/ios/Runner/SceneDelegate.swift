import Flutter
import UIKit
import app_links

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    // app_links 6 uses UIApplicationDelegate callbacks. With UIScene, launch
    // URLs arrive here instead; warm links still use Flutter's forwarding.
    // Save the launch URL in the plugin before Dart subscribes to its stream.
    if let url = connectionOptions.urlContexts.first?.url {
      AppLinks.shared.handleLink(url: url)
    } else if let url = connectionOptions.userActivities
      .first(where: { $0.activityType == NSUserActivityTypeBrowsingWeb })?.webpageURL {
      AppLinks.shared.handleLink(url: url)
    }
  }
}
