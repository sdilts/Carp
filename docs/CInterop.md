# C Interop
Interfacing C libraries with Carp programs requires 4 steps:
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
Carp structures and vice versa, with the exception of structures containing unions or arrays, which have no
directly translatable type in Carp. There are workarounds for
including arrays in structures detailed in [Workarounds for C arrays](#workarounds-for-c-arrays)

### Registering opaque types
Use the `register-type` function:

``` clojure
;; Register the "time_t" type
(register-type time_t)
```

### Registering C struct types
Use the `register-type` function. This function is used in the same manner as
`deftype`, although it cannot register union types.

``` clojure
;; Register structure
(register-type Person [name String, id Int])
```

### Workarounds for C arrays
Carp arrays contain metadata that makes them unable to be directly
substituted for C arrays. This means that we can't directly use Carp
arrays in structures. We can however, access them through their
pointers just like we can in C:

``` C
struct dynamic_array {
       int *array;
       int num_values;
       int capacity;
};
```
Is registered as:
``` clojure
(register-type dynamic_array [array (Ptr Int)
                              num_values Int
			      capacity Int])
```
However, it is impossible to register structs that contain a fixed
sized array. See issue [#507](https://github.com/carp-lang/Carp/issues/507) for updates on this topic.
``` C
struct example {
       // impossible to register:
       int array[5];
};
```

## Registering C functions, globals, and enums

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

### Registering C global variables
To register global variables such as `pi`, the register function is used again:
``` clojure
;; (register <constant-name> <type>)
(register pi Double)
```

### Registering C enums
Since Carp doesn't directly support enums, emum literals are imported
as constants:
``` C
enum categories {
     FRUIT,
     VEGETABLE,
};
```
``` clojure
(register FRUIT Int)
(register VEGETABLE Int)
```
