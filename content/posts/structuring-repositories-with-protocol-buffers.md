---
layout: post
title:  "Go: Structuring repositories with protocol buffers"
date:   2020-03-01
tags: 
    - golang 
    - protobuf 
    - structure 
    - grpc
    - tutorial
---

## Introduction

In my current position at [Utility Warehouse](https://www.utilitywarehouse.co.uk/), my team keeps our go code for all 
our services within a monorepo. This includes all our protocol buffer definitions that are used to generate client/service 
code to allow our services to interact.

This post aims to outline our way of organising our protocol buffer code and how we perform code generation to ensure all
services are up-to-date with the latest contracts when things change. This posts expects you to already be familiar with
protocol buffers.

You could also use the structure explained in this post to create a single repository that contains all proto definitions 
for all services (or whatever else you use them for) and serve it as a [go module](https://blog.golang.org/using-go-modules). 

## What are protocol buffers?

Taken from [Google's documentation](https://developers.google.com/protocol-buffers)

>Protocol buffers are Google's language-neutral, platform-neutral, extensible mechanism for serializing structured data 
– think XML, but smaller, faster, and simpler. You define how you want your data to be structured once, then you can 
use special generated source code to easily write and read your structured data to and from a variety of data streams 
and using a variety of languages.

On top of using them for service-to-service communication, we also use them as our serialization format for
the event-sourced aspects of our systems, where proto messages are sent over the wire via 
[Apache Kafka](https://kafka.apache.org/) and [NATS](https://nats.io/). Which also allows systems that consume/produce
events to always have the most up-to-date definitions.

## The 'proto' directory

At the top level of our repository lives the `proto` directory. This is where all `.proto` files live, as well as 
third-party definitions (such as those [provided by google](https://github.com/googleapis/googleapis/tree/master/google/type) 
or from other teams within the business).

Our team is the partner platform, so our specific proto definitions are found in a subdirectory named `partner`. Below 
this are the different domains we deal with. Subdirectories here include aspects such as `identity`, or `document` for 
services that deal with authentication or the management of individual partner's documents.

Below here are either versioned or service directories. Let's say we have a gRPC API that serves documents for a partner,
the proto definitions will are found under `partner/document/service/v*` (where `*` is the major version number for the 
service). Alternatively, if we have domain objects we want to share across multiple proto packages, we keep those under 
`partner/document/v*`. Using versioned directories like this allows us to version our proto packages easily and have the 
package names reflect the location of those files within the repository.

Here's a full example of what this looks like:

```
.
└── proto
    ├── partner
    │   └── document
    │       ├── service
    │       │   └── v1
    |       |       └── service.proto  # gRPC service definitions, DTOs etc
    │       └── v1
    |           └── models.proto       # Shared domain objects
```

## Writing protocol buffer definitions

Next, lets take a look at how we actually define our protocol buffers. There's nothing particularly out of the ordinary 
here that you wouldn't see in most other definitions. The most important part is the `package` declaration. We make sure
our package names reflect the relative location of the protocol buffer files. In the example above, the packages are named
`partner.document.service.v1` and `partner.document.v1`.

Here's an example of what the top of our `.proto` files look like:

```proto
syntax = "proto3";

// Additional imports go here

package partner.document.service.v1;

option go_package = "github.com/utilitywarehouse/<repo>/proto/gen/go/partner/document/service/v1;document";

// Service & message definitions go here
```

We're also using the [buf](https://buf.build/) tool in order to lint our files and check for breaking changes.

## Generating code from protocol buffers

Finally, we need to generate our code so we can use it in our go services. We commit and keep all our generated source 
code within the repository along with the definitions. This means that when code is regenerated, all services that 
depend on that generated code are updated at once.

To achieve our code generation, we use a bash script that finds all directories containing at least one `.proto` file
and runs the `protoc` command. This will output our generated code in directories relative to the respective `.proto` 
files within a `proto/gen/go` subdirectory. If we wanted to extend this to other languages (Java, TypeScript etc), these 
would be kept underneath `proto/gen/<language_name>`.

The script lives at `proto/generate.sh`, the important part looks like this:

```bash
#!/usr/bin/env bash

# Get current directory.
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Find all directories containing at least one prototfile.
# Based on: https://buf.build/docs/migration-prototool#prototool-generate.
for dir in $(find ${DIR}/partner -name '*.proto' -print0 | xargs -0 -n1 dirname | sort | uniq); do
  files=$(find "${dir}" -name '*.proto')

  # Generate all files with protoc-gen-go.
  protoc -I ${DIR} --go_out=plugins=grpc,paths=source_relative:${DIR}/gen/go ${files}
done
```

We also have some extra utilities, such as running additional generators when certain `import` directives are used within
the proto definitions. For example, if [go-proto-validators](https://github.com/mwitkow/go-proto-validators) are used 
within a definition. We will also generate code using `--govalidators_out`. Rinse and repeat for some additional tooling 
and some internal ones.

## Generated package names

If you're anal like myself, you may not like the go package names you get as a result of this. In the example above, you 
end up with a package name of `partner_document_v1`, which isn't pretty to look at unless you alias it when importing it.

To solve this, you can specify `option go_package` in order to override the generated package name. This is purely 
optional, but it allows us to have package names like `document` instead. You can read more about this option
[here](https://developers.google.com/protocol-buffers/docs/reference/go-generated)

## Links

* [https://www.utilitywarehouse.co.uk/](https://www.utilitywarehouse.co.uk/)
* [https://blog.golang.org/using-go-modules](https://blog.golang.org/using-go-modules)
* [https://developers.google.com/protocol-buffers](https://developers.google.com/protocol-buffers)
* [https://kafka.apache.org/](https://kafka.apache.org/)
* [https://nats.io/](https://nats.io/)
* [https://buf.build/](https://buf.build/)
* [https://github.com/googleapis/googleapis/tree/master/google/type](https://github.com/googleapis/googleapis/tree/master/google/type)
* [https://github.com/mwitkow/go-proto-validators](https://github.com/mwitkow/go-proto-validators)
* [https://developers.google.com/protocol-buffers/docs/reference/go-generated](https://developers.google.com/protocol-buffers/docs/reference/go-generated)
