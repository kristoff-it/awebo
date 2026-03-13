// Used to check if the deinit function truly deinits an objective c manager
// object.

#ifdef DEBUG
#define DDAssertLastRef(obj)                                                   \
  do {                                                                         \
    __weak __typeof__(obj) _weak = (obj);                                      \
    (obj) = nil;                                                               \
    NSCAssert(_weak == nil,                                                    \
              @"" #obj " still has live references after release");            \
  } while (0)
#else
#define DDAssertLastRef(obj) ((obj) = nil)
#endif