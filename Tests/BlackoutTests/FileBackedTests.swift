import Testing

/// Parent of every suite that repoints one of the library's file locations
/// (state, settings, lock) at a temporary directory. Those locations are
/// process-wide statics, so the suites must not run alongside each other;
/// .serialized applies to the nested suites too.
@Suite(.serialized)
enum FileBackedTests {}
