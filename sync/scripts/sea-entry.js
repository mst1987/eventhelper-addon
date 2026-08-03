"use strict";

// Einstiegspunkt der gepackten .exe.
//
// In einer Single Executable Application ist `require.main` nicht gesetzt, die
// übliche `require.main === module`-Weiche in index.js greift dort also nicht.
// Deshalb dieser eigene Einstieg, der run() direkt aufruft.
require("../index.js").run();
