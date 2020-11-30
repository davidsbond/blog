---
layout: post
title:  "Golang: Creating distributed systems using memberlist"
date:   2019-04-14
tags: golang hashicorp memberlist clusters
---

# Introduction

As scaling requirements have increased steadily throughout enterprise software the need to create distributed systems has increased. Leading to a variety of incredibly scalable products that rely on a distributed architecture. Wikipedia describes a distributed system as:

> A system whose components are located on different networked computers, which communicate and coordinate their actions by passing messages to one another.

Examples of these systems range from data stores to event buses and so on. There are many applications for distributed systems. Because there are so many applications, there are also many off-the-shelf implementations of these distributed communications protocols that allow us to easily build self-discovering, distributed systems. This post aims to go into detail on the [memberlist](https://github.com/hashicorp/memberlist) package and demonstrate how you can start building a distributed system using it.

I've currently used the library to create [sse-cluster](https://github.com/davidsbond/sse-cluster), a scalable [Server Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events) broker. It utilises memberlist in order to discover new nodes and propagate events to clients spread across different nodes. It was born from a need to scale an existing SSE implementation. It's a half decent reference for using the package. I have yet to delve much into the fine-tuning aspect of the configuration.

So what is [memberlist](https://github.com/hashicorp/memberlist)?

> Memberlist is a Go library that manages cluster membership and member failure detection using a gossip-based protocol.

Sounds great, but what is a gossip-based protocol?

Imagine a team of developers who like to spread rumours about their coworkers. Let's say every hour the developers congregate around the water cooler (or some equally banal office space). Each developer pairs off with another randomly and shares their new rumours with each other.

At the start of the day, Chris starts a new rumour: commenting to Alex that he believes that Mick is paid twice as much as everyone else. At the next meeting, Alex tells Marc, while Chris repeats the idea to David. After each rendezvous, the number of developers who have heard the rumour doubles (except in scenarios where a rumour has already been heard via another developer and has effectively been spread twice). Distributed systems typically implement this type of protocol with a form of random "peer selection": with a given frequency, each machine picks another machine at random and shares any hot, spicy rumours.

This is a loose description of how an implementation of a gossip protocol may work. The memberlist package utilises [SWIM](https://prakhar.me/articles/swim/) but has been modified to increase propagation speeds, convergence rates and general robustness in the face of processing issues (like networking delays). [Hashicorp](https://www.hashicorp.com/) have released a paper on this named [Lifeguard: SWIM-ing with Situational Awareness](https://arxiv.org/abs/1707.00788), which goes into full detail on these modifications.

With this package, we're able to create a self-aware cluster of nodes that can perform whatever tasks we see fit.

# Creating a simple cluster

To start, we'll need to define our configuration. The package contains some methods for generating default configuration based on the environment you intend to run your cluster in. Here they are:

* [DefaultLANConfig](https://github.com/hashicorp/memberlist/blob/master/config.go#L226) (Best for local networks):
  * Uses the hostname as the node name
  * Uses `7946` as the port for gossip communication
  * Has a 10 second TCP timeout

* [DefaultLocalConfig](https://github.com/hashicorp/memberlist/blob/master/config.go#L283) (Best for loopback environments):
  * Based on `DefaultLANConfig`
  * Has a 1 second TCP timeout

* [DefaultWANConfig](https://github.com/hashicorp/memberlist/blob/master/config.go#L267) (Best for nodes on WAN environments):
  * Based on `DefaultLANConfig`
  * Has a 1 second TCP timeout

We're going to run a 3 node cluster on a development machine, so we currently only need `DefaultLocalConfig`. We can initialize it like so:

```go
config := memberlist.DefaultLocalConfig()

list, err := memberlist.Create(c)

if err != nil {
  panic(err)
}
```

If we want, we can also broadcast some custom metadata for each node in the cluster. This is useful if you want to use slightly varying configuration between nodes but still want them to communicate. This does not impact the operation of the memberlist itself, but can be used when building applications on top of it.

```go
node := list.LocalNode()

// You can provide a byte representation of any metadata here. You can broadcast the
// config for each node in some serialized format like JSON. By default, this is
// limited to 512 bytes, so may not be suitable for large amounts of data.
node.Meta = []byte("some metadata")
```

This gets us as far as running a single node cluster. In order to join an existing cluster, we can use the `list.Join()` method to connect to one or more existing nodes. We can extend the example above to connect to an existing cluster.

```go
// Create an array of nodes we can join. If you're using a loopback
// environment you'll need to make sure each node is using its own
// port. This can be set with the configuration's BindPort field.
nodes := []string{
  "0.0.0.0:7946"
}

if _, err := list.Join(nodes); err != nil {
  panic(err)
}
```

From here, we've successfully configured the client and joined an existing cluster. The package will output some logs so you can see the nodes syncing with each other as well as any errors they run into. On top of this, we need to gracefully leave the memberlist once we're done. If we don't handle a graceful exit, the other nodes in the cluster will treat it as a dead node, rather than one that has
left.

To do this, we need to listen for a signal to exit the application, catch it and leave the cluster:

```go
// Create a channel to listen for exit signals
stop := make(chan os.Signal, 1)

// Register the signals we want to be notified, these 3 indicate exit
// signals, similar to CTRL+C
signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)

<-stop

// Leave the cluster with a 5 second timeout. If leaving takes more than 5
// seconds we return.
if err := ml.Leave(time.Second * 5); err != nil {
  panic(err)
}
```

# Communication between members

Now that we can join and leave the cluster, we can use the member list to perform distributed operations.

Let's create a simple messaging system. We could take a message via HTTP on a single node and propagate it to the next node in the cluster. This gives us an eventually consistent system that could be adapted into some sort of event bus.

This is by no means an optimal solution but demonstrates the power of service discovery in a clustered environment.

Let's start with a node:

```go
type (
  // The Node type represents a single node in the cluster, it contains
  // the list of other members in the cluster and an HTTP client for
  // directly messaging other nodes.
  Node struct {
    memberlist *memberlist.Memberlist
    http       *http.Client
  }
)
```

Imagine this node receives a message from an HTTP handler that just takes the entire request body and forwards it to another node. We can implement a method that will iterate over members in the list and attempt to forward a message. Once the message has been successfully forwarded to a single node, it stops handling it. This means we have eventual consistency where __eventually__ all nodes receive all messages.

```go
func (n *Node) HandleMessage(msg []byte) {
  // Iterate over all members in the cluster
  for _, member := range n.memberlist.Members() {
    // We also need to make sure we don't send the message to the node
    // currently processing it
    if member == n.memberlist.LocalNode() {
      continue
    }

    // Memberlist gives us the IP address of every member. In this example,
    // they all handle HTTP traffic on port 8080. You can also provide custom
    // metadata for your node to provide interoperability between nodes with
    // varying configurations.
    url := fmt.Sprintf("http://%s:8080/publish", member.Addr)
    resp, err := n.http.Post(url, "application/json", bytes.NewBuffer(msg))

    if err != nil {
      // handle error and try next node
      continue
    }

    if resp.StatusCode != http.StatusOK {
      // handle unexpected status code and try next node
      continue
    }

    // Otherwise, we've forwarded the message and can do
    // something else.
    break
  }
}
```

Hopefully, this post has outlined how you can use the `memberlist` package to implement a clustered application. The library is very powerful and allows you to focus on the actual logic your cluster depends on rather than the underlying network infrastructure. In my experience, the time taken for members to synchronise is negligible, but you should keep in mind the protocol is eventual.

In the example above, we can't guarantee that our message will be propagated to every single node if there is a lot of traffic in terms of nodes joining/leaving. Ideally, new members should join in a controlled manner and only when necessary.

# Links

* [https://en.wikipedia.org/wiki/Distributed_computing](https://en.wikipedia.org/wiki/Distributed_computing)
* [https://github.com/hashicorp/memberlist](https://github.com/hashicorp/memberlist)
* [https://github.com/davidsbond/sse-cluster](https://github.com/davidsbond/sse-cluster)
* [https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events)
* [https://prakhar.me/articles/swim/](https://prakhar.me/articles/swim/)
* [https://www.hashicorp.com/](https://www.hashicorp.com/)
* [https://arxiv.org/abs/1707.00788](https://arxiv.org/abs/1707.00788)
