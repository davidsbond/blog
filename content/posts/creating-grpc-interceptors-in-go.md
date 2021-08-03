---
layout: post
title:  "Go: Creating gRPC interceptors"
date:   2019-06-14
tags: 
    - golang 
    - grpc 
    - middleware 
    - interceptors
    - tutorial
---

## Introduction

Just like when building HTTP APIs, sometimes you need middleware that applies to your HTTP handlers for things like
request validation, authentication etc. In [gRPC](https://grpc.io/) this is no different. Methods for authentication
need to be applied to both servers and clients in an 'all or none' fashion. For the uninitiated, gRPC describes itself
as:

>A modern open source high performance RPC framework that can run in any environment. It can efficiently connect services in and across data centers with pluggable support for load balancing, tracing, health checking and authentication. It is also applicable in last mile of distributed computing to connect devices, mobile applications and browsers to backend services.

The key difference here is that in HTTP we create middleware for handlers (purely on the server side). With gRPC we can create middleware
for both inbound calls on the server side and outbound calls on the client side. This post aims to outline how you can create simple gRPC interceptors
that act as middleware for your clients and servers.

## Interceptor Types

In gRPC there are two kinds of interceptors, **unary** and **stream**. Unary interceptors handle single request/response RPC calls whereas stream interceptors handle RPC calls where streams
of messages are written in either direction. You can get more in-depth details on the differences between them [here](https://grpc.io/docs/guides/concepts/#rpc-life-cycle). On top of this, you can
create interceptors that apply to both servers and clients.

### Unary Client Interceptors

In situations where we have a simple call & response, we need to create a unary client interceptor. This is a function that matches
the signature of `grpc.UnaryClientInterceptor` and looks like this:

```go
func Interceptor(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
  // Do some things and invoke `invoker` to finish the request
}
```

This signature has a lot of parameters, so lets look at each one and what they're for:

* `ctx context.Context` - This is the request context and will be used primarily for timeouts. It can also be used to add/read request metadata.
* `method string` - The name of the RPC method being called.
* `req interface{}` - The request instance, this is an `interface{}` as reflection is used for the marshalling
* `reply interface{}` - The response instance, works the same way as the `req` parameter
* `cc *grpc.ClientConn` - The underlying client connection to the server.
* `invoker grpc.UnaryInvoker` - The RPC invocation method. Similarly to [HTTP middleware](https://gist.github.com/gbbr/935f26e50080ae99eedc822d8c273a89#file-middleware_funcs-go) where you call `ServeHTTP`, this needs to be invoked for the RPC call to be made.
* `opts ...grpc.CallOption` - The `grpc.CallOption` instances used to configure the gRPC call.

With all of these, we get a lot of information about the call being made. This makes it quite straightforward to create things like [logging middleware](https://github.com/grpc-ecosystem/go-grpc-middleware/blob/master/logging/logrus/client_interceptors.go) that will write out
RPC call information.

### Unary Server Interceptors

Server interceptors look fairly similar to the client, with the exception that they allow us to modify the response returned from
the gRPC call. Here's the function signature, it's defined as `grpc.UnaryServerInterceptor`:

```go
func Interceptor(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
    // Invoke 'handler' to use your gRPC server implementation and get
    // the response.
}
```

Like with the client, there's a few different params here:

* `ctx context.Context` - This is the request context and will be used primarily for timeouts. It can also be used to add/read request metadata.
* `req interface{}` - The inbound request
* `info *grpc.UnaryServerInfo` - Information on the gRPC server that is handling the request
* `handler grpc.UnaryHandler` - The handler for the inbound request, you'll need to invoke this otherwise you won't be getting your response to the client.

### Stream Client Interceptors

Working with streams works pretty much the same, here's the signature of `grpc.StreamClientInterceptor`:

```go
func Interceptor(ctx context.Context, desc *grpc.StreamDesc, cc *grpc.ClientConn, method string, streamer grpc.Streamer, opts ...grpc.CallOption) (grpc.ClientStream, error) {
    // Call 'streamer' to write messages to the stream before this function returns
}
```

* `ctx context.Context` - This is the request context and will be used primarily for timeouts. It can also be used to add/read request metadata.
* `desc *grpc.StreamDesc` - Represents a streaming RPC service's method specification.
* `cc *grpc.ClientConn` - The underlying client connection to the server.
* `method string` - The name of the gRPC method being called.
* `streamer grpc.Streamer` - Called by the interceptor to create a stream.

### Stream Server Interceptors

Below is the signature of `grpc.StreamServerInterceptor`

```go
func Interceptor(srv interface{}, stream grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
    // Call 'handler' to invoke the stream handler before this function returns
}
```

* `srv interface{}` - The server implementation
* `stream grpc.ServerStream` - Defines the server-side behavior of a streaming RPC.
* `info *grpc.StreamServerInfo` - Various information about the streaming RPC on server side
* `handler grpc.StreamHandler` - The handler called by gRPC server to complete the execution of a streaming RPC

## Creating an interceptor

For this post, lets say we have a gRPC client and server that authenticate via a JWT token that we obtain via an HTTP API. If the provided
JWT token is no longer valid, the server will return an appropriate status code that will be detected
by the interceptor, triggering a call to the HTTP API to refresh the token. We're going to use a unary client interceptor to achieve this, but the
code can be easily ported for client streams and servers.

**Note:** There are plenty of open-source implementations for token-based authentication on gRPC, the code in this post is just to serve as an
example. Ideally, you'll want something stronger than just a username and password combo. You can check out lots of different interceptor implementations in the [grpc-ecosystem/go-grpc-middleware](https://github.com/grpc-ecosystem/go-grpc-middleware) repository

To start, we'll need a type to store our JWT token and authentication details, we're going to use basic auth to obtain the token.

```go
type (
    JWTInterceptor struct {
        http     *http.Client // The HTTP client for calling the token-serving API
        token    string       // The JWT token that will be used in every call to the server
        username string       // The username for basic authentication
        password string       // The password for basic authentication
        endpoint string       // The HTTP endpoint to hit to obtain tokens
    }
)
```

Next, we'll need our unary client interceptor that will add the JWT token to the request metadata for each outbound call, we're following the [bearer token](https://oauth.net/2/bearer-tokens/) approach:

```go
func (jwt *JWTInterceptor) UnaryClientInterceptor(ctx context.Context, method string, req interface{}, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
    // Add the current bearer token to the metadata and call the RPC
    // command
    ctx = metadata.AppendToOutgoingContext(ctx, "authorization", "bearer "+t.token)
    return invoker(ctx, method, req, reply, cc, opts...)
}
```

The above will work for as long as the JWT token is valid. If the token has an expiry, we will eventually no longer be able to make calls to the server. So we need a method that can call the HTTP
API that serves us tokens. The API accepts a JSON body and returns the token in the response body, we'll also need some types to represent those

```go
type(
    authResponse struct {
        Token string `json:"token"`
    }

    authRequest struct {
        Username string `json:"username"`
        Password string `json:"password"`
    }
)
```

Here are the functions for obtaining new JWT tokens. The API called will give back a 200 response with a JSON encoded body containing the token. It returns errors using `http.Error` so those are just string responses. Once we have the token, we set it on the `JWT` struct for later use.

```go
func (jwt *JWTInterceptor) refreshBearerToken() error {
    resp, err := jwt.performAuthRequest()

    if err != nil {
        return err
    }

    var respBody authResponse
    if err = json.NewDecoder(resp.Body).Decode(&respBody); err != nil {
        return err
    }

    jwt.token = respBody.Token

    return resp.Body.Close()
}

func (jwt *JWTInterceptor) performAuthRequest() (*http.Response, error) {
    body := authRequest{
        Username: jwt.username,
        Password: jwt.password,
    }

    data, err := json.Marshal(body)

    if err != nil {
        return nil, err
    }

    buff := bytes.NewBuffer(data)
    resp, err := jwt.http.Post(jwt.endpoint, "application/json", buff)

    if err != nil {
        return resp, err
    }

    if resp.StatusCode != http.StatusOK {
        out := make([]byte, resp.ContentLength)
        if _, err = resp.Body.Read(out); err != nil {
            return resp, err
        }

        return resp, fmt.Errorf("unexpected authentication response: %s", string(out))
    }

    return resp, nil
}

```

With these defined, we can update our interceptor logic like so:

```go
func (jwt *JWTInterceptor) UnaryClientInterceptor(ctx context.Context, method string, req interface{}, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
    // Create a new context with the token and make the first request
    authCtx := metadata.AppendToOutgoingContext(ctx, "authorization", "bearer "+jwt.token)
    err := invoker(authCtx, method, req, reply, cc, opts...)

    // If we got an unauthenticated response from the gRPC service, refresh the token
    if status.Code(err) == codes.Unauthenticated {
        if err = jwt.refreshBearerToken(); err != nil {
            return err
        }

        // Create a new context with the new token. We don't want to reuse 'authCtx' here
        // because we've already appended the invalid token. We're appending metadata to
        // a slice here rather than a map like HTTP headers, so the first one will be picked
        // up and invalid.
        updatedAuthCtx := metadata.AppendToOutgoingContext(ctx, "authorization", "bearer "+jwt.token)
        err = invoker(updatedAuthCtx, method, req, reply, cc, opts...)
    }

    return err
}
```

## Testing an interceptor

Now that we've written the interceptor, we need some tests. It can be a little tricky asserting values within a context when your packages
don't define the keys that are used. Luckily the `google.golang.org/grpc/metadata` contains methods we can use to get the information we need
and assert that it is what we expect. We're going to implement our own version of the `invoker` method that will assert the existence
of the JWT token in the metadata. We can then just call the `JWTInterceptor.UnaryClientInterceptor` method directly in our test, without connecting
to or mocking a gRPC service.

I normally write using [table driven tests](https://github.com/golang/go/wiki/TableDrivenTests), but for the sake of brevity I'll just go through the steps
you can take to pull the token out from the context and check its value.

* In your custom invoker function, pull the outgoing metadata using `metadata.FromOutgoingContext(ctx)`
* Convert your outbound context into an inbound one using `metadata.NewIncomingContext(ctx, md)` with the metadata from above.
* Extract the JWT token using `github.com/grpc-ecosystem/go-grpc-middleware/auth` and the `AuthFromMD` method.
* If the token isn't what you expect or is blank, return `codes.Unauthenticated` using the `google.golang.org/grpc/codes` package.
* Use a HTTP mock to catch the request for a token and handle it. (Either using the standard library or an HTTP mocking package like [gock](https://github.com/h2non/gock))

## Using an interceptor

With our interceptor written, we can apply it using the `grpc.With...` methods like so:

```go
// Create a new interceptor
jwt := &JWTInterceptor{
    // Set up all the members here
}

conn, err := grpc.Dial("localhost:5000", grpc.WithUnaryInterceptor(jwt.UnaryClientInterceptor))

// Perform the rest of your client setup
```

This works the same for servers as well. When you create your server you'll have the option on providing
unary/stream server interceptors.

## Links

* [https://grpc.io/](https://grpc.io/)
* [https://grpc.io/docs/guides/concepts/#rpc-life-cycle](https://grpc.io/docs/guides/concepts/#rpc-life-cycle)
* [https://github.com/grpc-ecosystem/go-grpc-middleware/blob/master/logging/logrus/client_interceptors.go](https://github.com/grpc-ecosystem/go-grpc-middleware/blob/master/logging/logrus/client_interceptors.go)
* [https://gist.github.com/gbbr/935f26e50080ae99eedc822d8c273a89#file-middleware_funcs-go](https://gist.github.com/gbbr/935f26e50080ae99eedc822d8c273a89#file-middleware_funcs-go)
* [https://oauth.net/2/bearer-tokens/](https://oauth.net/2/bearer-tokens/)
* [https://github.com/grpc-ecosystem/go-grpc-middleware](https://github.com/grpc-ecosystem/go-grpc-middleware)
* [https://github.com/golang/go/wiki/TableDrivenTests](https://github.com/golang/go/wiki/TableDrivenTests)
* [https://github.com/h2non/gock](https://github.com/h2non/gock)
