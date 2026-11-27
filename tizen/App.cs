using Tizen.Flutter.Embedding;
using Tizen.System;

namespace Runner
{
    // VyseTV on a Samsung TV (see tizen/README.md). Everything the app does is in Dart; this only
    // starts Flutter and registers the plugins' Tizen sides (the file flutter-tizen writes).
    public class App : FlutterApplication
    {
        protected override void OnCreate()
        {
            // Laid out as an Android TV lays it out: 960 by 540 points. Samsung's engine gives a
            // TV a scale of 1.6 (a fixed 72 dpi, times 2, over 90), so a 1080p set was 1200 by
            // 675 points: neither the TV layout every remote round was tuned on nor a desktop's,
            // and a tester's set showed overlaps there. At most 2, so a TV that reports a 4K
            // screen for a 1080p interface is never laid out smaller than that.
            if (Information.TryGetValue("http://tizen.org/feature/screen.width", out int width) && width > 0)
            {
                UserPixelRatio = global::System.Math.Min(global::System.Math.Max(width / 960.0, 1.0), 2.0);
            }

            base.OnCreate();

            GeneratedPluginRegistrant.RegisterPlugins(this);
        }

        static void Main(string[] args)
        {
            var app = new App();
            app.Run(args);
        }
    }
}
