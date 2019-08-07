Interfacing C librapries with Carp programs requires 4 steps:
1. Include any required library header files.
2. Add the required information needed for building.
3. Register any structures or types that are used in the library.
4. Register any functions and globals that are used in the library.


## Including header files

If the header file is found in a relative path to the current file, use `local-include`, and
if the header is a system file, use `system-include`:
``` clojure
(system-include "math.h") ;; compiles to #include <math.h>
(local-include "math.h") ;; compiles to #include "math.h"
```


## Adding information needed for building

To add build information to Carp, the `add-pkg`, `add-cflag`, and `add-lib` functions are used.
- `add-pkg`: Adds compiler and linker flags sourced from `pkg-config`
- `add-cflag`: Adds a compiler flag
- `add-library`: Adds a linker flag


## Registering C types

### Carp types vs C types
Carp number types and the `String` type directly correspond to the same types in C, with `String`
being a stand in for `char*`. This means that any C function or struct that uses one of these types is trivially
usable in Carp. The same concept applies to structures: most structures in C are directly translatable to
Carp structures and vice versa, with the exception of structures containing unions and arrays, which have no
directly translatable type in Carp.

<!-- These are bold claims: are they all correct? -->
Carp arrays contain metadata that makes them unable to be directly substituted for C arrays, and Carp's sum types
are incompatible with `unions` in C. Wrapper functions can be written to deal with these incompatibilities when using
these types as function parameters and function return values, but there is no way to instantiate these types directly
in Carp.

### Registering C types in Carp
To make a C type available in Carp, you use the `register-type` function. This function is used in the same manner as
`deftype`, and can be used to register opaque types as well as C structs.

``` clojure
;; Register opaque type
(register-type thing)
;; Register structure
(register-type Person [name String, id Int])
```


## Registering C functions and globals

### Registering C functions
To make Carp aware of C functions, you must register them with the `register` function.
``` clojure
;; Register function with signature
;; char *blah(int, int)
(register blah  (Fn [Int Int] String))
```
If you want to call a function by a different name in Carp code than
its actual name in C code, include the actual name of the function as the last
argument to `register`:
``` clojure
;; register the C function "actual_name" as the function "my-func-name"
(register my-func-name (Fn [Int] void) "actual_name")
```

### Registering C globals
``` clojure
(register pi Double)
```