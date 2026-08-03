import js from "@eslint/js";

export default [
    js.configs.recommended,
    {
        files: ["**/*.js"],
        languageOptions: {
            ecmaVersion: 2022,
            sourceType: "commonjs",
            globals: {
                require: "readonly",
                module: "writable",
                process: "readonly",
                console: "readonly",
                __dirname: "readonly",
                fetch: "readonly",
                setTimeout: "readonly",
                setInterval: "readonly",
                clearInterval: "readonly",
            },
        },
        rules: {
            indent: ["error", 4],
            // Wie im EventHelper-Repo doppelte Anführungszeichen, aber mit
            // avoidEscape: die Tests enthalten Lua-Quelltext, in dem doppelte
            // Anführungszeichen vorkommen — die sonst nötigen Escapes machen
            // genau die Zeilen unlesbar, auf die es dort ankommt.
            quotes: ["error", "double", { avoidEscape: true }],
            semi: ["error", "always"],
        },
    },
    {
        files: ["test/**/*.js"],
        languageOptions: {
            globals: {
                describe: "readonly", it: "readonly", expect: "readonly",
                jest: "readonly", beforeEach: "readonly", afterEach: "readonly",
                global: "writable",
            },
        },
    },
];
