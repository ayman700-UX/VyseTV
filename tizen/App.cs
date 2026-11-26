using Tizen.Flutter.Embedding;

namespace Runner
{
    // VyseTV on a Samsung TV (see tizen/README.md). Everything the app does is in Dart; this only
    // starts Flutter and registers the plugins' Tizen sides (the file flutter-tizen writes).
    public class App : FlutterApplication
    {
        protected override void OnCreate()
        {
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
