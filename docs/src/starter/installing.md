---
title: Installing dex
description: Assuming you’ve already installed the D compiler (DMD or LDC) and DUB, creating a new dex project takes less than a minute.
---

## Prerequisites

`dex` requires **DMD 2.100+** or **LDC 1.30+** along with the **DUB** package manager. If you haven't installed them yet, you can get them using the official installer script:

```sh title="Terminal"
$ curl -fsS https://dlang.org/install.sh | bash -s dmd
```

## Step 1: Create a Project Directory

Create a directory to hold your application and make it your working directory:

```sh title="Terminal"
$ mkdir myapp
$ cd myapp
```

## Step 2: Initialize DUB Project

Use `dub init` to create a minimal application descriptor:

```sh title="Terminal"
$ dub init -t minimal -n
```

## Step 3: Install dex

Add `dex` as a dependency to your `dub.json` file:

```sh title="Terminal"
$ dub add dex
```

Alternatively, you can edit your `dub.json` directly to include `dex`:

```json title="dub.json"
{
    "name": "myapp",
    "description": "My web application",
    "dependencies": {
        "dex": "~>0.5.0"
    }
}
```

## Manual Installation (Without DUB)

Because `dex` has **zero external runtime dependencies** (relying purely on standard Phobos and druntime), you do not need DUB to build or run applications. You can compile directly with **DMD** or **LDC**.

### Option A: Direct Compilation with `-i` (Compiler-Assisted Imports)

Clone `dex` or include it as a git submodule:

```sh title="Terminal"
$ git clone https://github.com/ernlel/dex.git
```

Use D's automatic import compiler flag (`-i`) to compile your application and link dex modules in one step:

```sh title="Terminal"
# With DMD
$ dmd -i -Idex/source app.d -of=myapp

# With LDC
$ ldc2 -i -Idex/source app.d -of=myapp
```

### Option B: Build Static Library (`libdex.a`) via Makefile

You can build a standalone static library archive using the included `Makefile`:

```sh title="Terminal"
$ cd dex
$ make
$ make test
$ sudo make install  # Installs to /usr/local/lib and /usr/local/include/d/dex
```

Then compile your project linking against `libdex.a`:

```sh title="Terminal"
$ dmd -I/usr/local/include/d/dex app.d -L-ldex -of=myapp
```

### Option C: Pre-Packaged Minimal Release Archives

If you prefer not to clone the full repository or don't have git installed in your build container, you can download minimal standalone release archives (~38 KiB) from the [GitHub Releases](https://github.com/ernlel/dex/releases) page. These packages contain only the core library files (`source/dex/*.d`), `LICENSE`, `dub.json`, and `Makefile`:

```sh title="Terminal"
# Download and unpack minimal library source package
$ curl -fsSL https://github.com/ernlel/dex/releases/download/v0.5.0/dex-0.5.0.tar.gz | tar -xz

# Compile your app against the unpacked sources
$ dmd -i -Idex-0.5.0/source app.d -of=myapp
```

> **Zero External Dependencies**
>
> `dex` does not require libevent, libuv, OpenSSL, or external C shared libraries. It builds directly against the standard Phobos library with instant compile times.
