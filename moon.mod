// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "moonsage/moonsage"

version = "0.1.0"

readme = "README.mbt.md"

license = "Apache-2.0"

keywords = [ "agent", "mooncakes", "packages", "moonbit" ]

preferred_target = "native"

description = "A MoonBit-native agent for exploring the Mooncakes package ecosystem."

import {
  "moonbitlang/x@0.4.47",
  "moonbitlang/async@0.20.3",
}
