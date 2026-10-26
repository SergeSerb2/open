// Main for the five CEF helper apps (Open Helper, (GPU), (Renderer),
// (Plugin), (Alerts)). All engine code lives in OpenEngine.framework.
#import <OpenEngine/OEEngine.h>

int main(int argc, char* argv[]) {
  return OEHelperMain(argc, argv);
}
