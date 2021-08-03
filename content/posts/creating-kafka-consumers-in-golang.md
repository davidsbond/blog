---
layout: post
title:  "Go: Implementing kafka consumers using sarama-cluster"
date:   2018-08-22
tags: 
    - golang 
    - kafka 
    - sarama 
    - cluster 
    - sarama-cluster 
    - tutorial
---

## Introduction

Nowadays it seems as though more and more companies are using event-based architectures to provide communication between services across various domains. [Confluent](http://confluent.io/) maintain a [huge list](https://cwiki.apache.org/confluence/display/KAFKA/Powered+By) of companies actively using [Apache Kafka](https://kafka.apache.org/), a high performance messaging system and the subject of this post.

Kafka has been so heavily adopted in part due to its high performance and the large number of client libraries available in a multitude of languages. 

The concept is fairly simple, clients either produce or consume events that are categorised under "topics". For example, a company like LinkedIn may produce an event against a `user_created` topic after a successful sign-up, allowing multiple services to asynchronously react and perform respective processing regarding that user. One service might handle sending me a welcome email, whereas another will attempt to identify other users I may want to connect with. 

Kafka events are divided into "partitions". These are parallel event streams that allow multiple consumers to process events from the same topic. Every event contains what is called an "offset", a number that represents where an event resides in the sequence of all events in a partition. Imagine all events for a topic partition are stored as an array, the offset would be the index where a particular event is located in time. This allows consumers to specify a starting point from which to consume events, granting the ability to avoid duplication of events processed, or the consumption of events produced earlier in time.

Consumers can then form "groups", where each consumer reads one or more unique partitions to spread the consumption of a topic across multiple consumers. This is especially useful when running replicated services and can increase event throughput.

## Implementing a Kafka consumer

There aren't a huge number of viable options when it comes to implementing a Kafka consumer in Go. This tutorial focuses on [sarama-cluster](https://github.com/bsm/sarama-cluster), a balanced consumer implementation built on top the existing [sarama](https://github.com/shopify/sarama) client library by [Shopify](https://www.shopify.com).

The library has a concise API that makes getting started fairly simple. The first step is to define our consumer configuration. We can use the `NewConfig` method which creates a default configuration with some sensible starting values

```go
// Create a configuration with some sane default values
config := cluster.NewConfig()
```

### Authentication

If you're sensible, the Kafka instance you're connecting to will have some form of authentication. The `sarama-cluster` library supports both TLS and SASL authentication methods.

If you're using TLS certificates, you can populate the `config.TLS` struct field:

```go
config := cluster.NewConfig()

// Load an X509 certificate pair like you would for any other TLS
// configuration
cert, err := tls.LoadX509KeyPair("cert.pem", "cert.key")

if err != nil {
  panic(err)
}

ca, err := ioutil.ReadFile("ca.pem")

if err != nil {
  panic(err)
}

pool := x509.NewCertPool()
pool.AppendCertsFromPEM(ca)

tls := &tls.Config{
  Certificates: []tls.Certificate{cert},
  RootCAs:      pool,
}

kafkaConfig.Net.TLS.Config = tls
```

It's important to note that if you're running your consumer within a docker image, you'll need to install `ca-certificates` in order to create an x509 certificate pool. In a Dockerfile based on alpine this looks like:

```Dockerfile
FROM alpine

RUN apk add --update ca-certificates
```

Alternatively, if you're using SASL for authentication, you can populate the `config.SASL` struct field like so:

```go
config := cluster.NewConfig()

// Set your SASL username and password
config.SASL.User = "username"
config.SASL.Password = "password"

// Enable SASL
config.SASL.Enable = true
```

### Implementing the consumer

Now that we've created a configuration with our authentication method of choice, we can create a consumer that will allow us to handle events for specified topics. You're going to need to know the addresses of your Kafka brokers, the name of your consumer group and each topic you wish to consume:

```go
consumer, err := cluster.NewConsumer(
  []string{"broker-address-1", "broker-address-2"},
  "group-id",
  []string{"topic-1", "topic-2", "topic-3"},
  kafkaConfig)

if err != nil {
  panic(err)
}
```

The `sarama-cluster` library allows you to specify a consumer mode within the config. It's important to understand the difference as your implementation will differ based on what you've chosen. This can be modified via the `config.Group.Mode` struct field and has two options. These are:

* `ConsumerModeMultiplex` - By default, messages and errors from the subscribed topics and partitions are all multiplexed and made available through the consumer's `Messages()` and `Errors()` channels.
* `ConsumerModePartitions` - Users who require low-level access can enable `ConsumerModePartitions` where individual partitions are exposed on the `Partitions()` channel. Messages and errors must then be consumed on the partitions themselves.

When using `ConsumerModeMultiplex`, all messages come from a single channel exposed via the `Messages()` method. Reading these messages looks like this:

```go
// The loop will iterate each time a message is written to the underlying channel
for msg := range consumer.Messages() {
  // Now we can access the individual fields of the message and react
  // based on msg.Topic
  switch msg.Topic {
    case "topic-1":
      handleTopic1(msg.Value)
      break;
    // ...
  }
}
```

If you want a more low-level implementation where you can react to partition changes yourself, you're going to want to use `ConsumerModePartitions`. This provides you the individual partitions via the `consumer.Partitions()` method. This exposes an underlying channel that partitions are written to when the consumer group rebalances. You can then use each partition to read messages and errors:

```go
// Every time the consumer is balanced, we'll get a new partition to read from
for partition := range consumer.Partitions() {
  // From here, we know exactly which topic we're consuming via partition.Topic(). So won't need any
  // branching logic based on the topic.
  for msg := range consumer.Messages() {
    // Now we can access the individual fields of the message
    handleTopic1(msg.Value)   
  }
}
```

The `ConsumerModePartitions` way of doing things will require you to code more oversight into your consumer. For one, you're going to need to gracefully handle the situation where the partition closes in a rebalance situation. These will occur when adding new consumers to the group. You're also going to need to manually call the `partition.Close()` method when you're done consuming.

## Handling errors & rebalances

Should you add more consumers to the group, the existing ones will experience a rebalance. This is where the assignment of partitions to each consumer changes for an optimal spread across consumers. The `consumer` instance we've created already exposes a `Notifications()` channel from which we can log/react to these changes. 

```go
  for notification := range consumer.Notifications() {
    // The type of notification we've received, will be
    // rebalance start, rebalance ok or error
    fmt.Println(notification.Type)

    // The topic/partitions that are currently read by the consumer
    fmt.Println(notification.Current)

    // The topic/partitions that were claimed in the last rebalance
    fmt.Println(notification.Claimed)

    // The topic/partitions that were released in the last rebalance
    fmt.Println(notification.Released)
  }
```

Errors are just as easy to read and are made available via the `consumer.Errors()` channel. They return a standard `error` implementation.

```go
  for err := range consumer.Errors() {
    // React to the error
  }
```

In order to enable the reading of notification and errors, we need to make some small changes to our configuration like so:

```go
config.Consumer.Return.Errors = true
config.Group.Return.Notifications = true
```

## Committing offsets

The last step in implementing the consumer is to commit our offsets. In short, we're telling Kafka that we have finished processing a message and we do not want to consume it again. This should be done once you no longer require the message data for any processing. If you commit offsets too early, you may lose the ability to easily reconsume the event if something goes wrong. Let's say you're writing the event contents straight to a database, don't commit offsets before you've written the contents of the event to your database successfully. That way, should the database operation fail, you can just reconsume the event to try again.

```go
// The loop will iterate each time a message is written to the underlying channel
for msg := range consumer.Messages() {
  // Now we can access the individual fields of the message and react
  // based on msg.Topic
  switch msg.Topic {
    case "topic-1":
      // Do everything we need for this topic
      handleTopic1(msg.Value)

      // Mark the message as processed. The sarama-cluster library will
      // automatically commit these.
      // You can manually commit the offsets using consumer.CommitOffsets()
      consumer.MarkOffset(msg)
      break;
      // ...
  }
}
```

This is everything you need in order to implement a simple Kafka consumer group. The `sarama-cluster` library provides a lot more configuration options to suit your needs based on how you maintain your Kafka brokers. I'd recommend browsing through all the config values yourself to determine if you need to tweak any.

## Links

* [http://confluent.io/](http://confluent.io/)
* [https://cwiki.apache.org/confluence/display/KAFKA/Powered+By](https://cwiki.apache.org/confluence/display/KAFKA/Powered+By)
* [https://kafka.apache.org/](https://kafka.apache.org/)
* [https://github.com/bsm/sarama-cluster](https://github.com/bsm/sarama-cluster)
* [https://github.com/shopify/sarama](https://github.com/shopify/sarama)
* [https://www.shopify.com](https://www.shopify.com)
