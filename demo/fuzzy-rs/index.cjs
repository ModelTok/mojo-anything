// Loads the wasm-bindgen (nodejs target) output built by `mojo-anything build`.
const native = require('./pkg/fuzzy_rs.js')
module.exports = native
