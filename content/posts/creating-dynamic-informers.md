---
layout: post
title: "Go: Creating Dynamic Kubernetes Informers"
date: 2021-08-04
tags: 
    - golang 
    - kubernetes 
    - informer  
    - dynamic
    - tutorial
---

## Introduction

Recently, I published v1.0.0 of [Kollect](https://github.com/davidsbond/kollect), a dynamic Kubernetes informer that
publishes changes in cluster resources to a configurable event bus. At the heart of this project is a dynamic informer,
a method of handling add/update/delete notifications of arbitrary cluster resources (including those added as a `CustomResourceDefinition`).

This kind of tooling is quite powerful, as you can perform operations on arbitrary resources without knowing their structure.
This is especially useful in situations where you cannot import the canonical types for those resources from public
repositories, or they're too large and complex to write your own types without a lot of time and effort.

For example, using Kollect (or your own informer), you can track changes to your resources in real time, or check that
resources follow best practices as they change, using a tool like [Open Policy Agent](https://www.openpolicyagent.org/).

In this post, I'll attempt to get you started writing a dynamic Kubernetes informer that will allow you to perform operations
when any resources of your choosing change.

## Getting Started

Every go project starts with initialising a new [Go module](https://blog.golang.org/using-go-modules):

```shell
go mod init github.com/myname/myinformer
```

And a `main.go`:

```go
package main

func main() {
	
}
```

## Cluster Authentication

In order to start handling notifications, we're going to need to authenticate with the cluster that we're running in or
against. This means we have two separate methods of authentication:

* Kubeconfig - Pointing directly to a kubeconfig file that our application accesses on startup. This would be used typically
when your program is not running in the cluster it is watching.
* In-cluster - Obtaining permissions based on the [ServiceAccount](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/) 
associated with the [Pod](https://kubernetes.io/docs/concepts/workloads/pods/) that our program is running in within the cluster we want to watch.

We're going to use the `k8s.io/client-go` package, so you'll need to run:

```shell
go get k8s.io/client-go
```

Now we've downloaded the dependency, let's update our `main.go` to create a Kubernetes API cluster config based on where 
our application is running:

```go
package main

import (
	"log"
	"os"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	kubeConfig := os.Getenv("KUBECONFIG")
	
	var clusterConfig *rest.Config
	var err error
	if kubeConfig != "" {
		clusterConfig, err = clientcmd.BuildConfigFromFlags("", kubeConfig)
	} else {
		clusterConfig, err = rest.InClusterConfig()
	}
	if err != nil {
		log.Fatalln(err)
	}

	clusterClient, err := dynamic.NewForConfig(clusterConfig)
	if err != nil {
		log.Fatalln(err)
	}
}
```

The code above checks for the presence of the `KUBECONFIG` environment variable, if it is present, we create our cluster
configuration using the `clientcmd` package. Otherwise, we use the `rest` package to assume credentials from the `Pod` 
we're running in. Then, we create a new dynamic client.

The `dynamic` package, allows us to query cluster resources as `unstructured.Unstructured` types. These are basically 
wrappers around `map[string]interface{}` that have helper methods for obtaining Kubernetes resource specifics such as the
API version, group, kind, labels, annotations etc.

## Monitoring Resources

Now that we've authenticated against the cluster, we can start monitoring resources. We'll do this with the `dynamicinformer`
package. We're also going to need to decide which resources we want to watch and create an informer for each one. In this
example, we'll create a single informer that watches `Deployment` resources, but you can easily extend it to watch
multiple resources.

```go
package main

import (
	"log"
	"os"
	"time"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/dynamic/dynamicinformer"
	"k8s.io/apimachinery/pkg/runtime/schema"
	corev1 "k8s.io/api/core/v1"
)

func main() {
	kubeConfig := os.Getenv("KUBECONFIG")
	
	var clusterConfig *rest.Config
	var err error
	if kubeConfig != "" {
		clusterConfig, err = clientcmd.BuildConfigFromFlags("", kubeConfig)
	} else {
		clusterConfig, err = rest.InClusterConfig()
	}
	if err != nil {
		log.Fatalln(err)
	}

	clusterClient, err := dynamic.NewForConfig(clusterConfig)
	if err != nil {
		log.Fatalln(err)
	}
	
	resource := schema.GroupVersionResource{Group:"apps", Version:"v1", Resource: "deployments"}
	factory := dynamicinformer.NewFilteredDynamicSharedInformerFactory(clusterClient, time.Minute, corev1.NamespaceAll, nil)
	informer := factory.ForResource(resource).Informer()
}
```

Notice that when we call `NewFilteredDynamicSharedInformerFactory`, we pass in `corev1.NamespaceAll` as the namespace to
watch resources in. This causes the informer to watch over all namespaces within the cluster. You can modify this to only
a specific namespace, or filter by namespace in the handler methods.

Now that we've created a new informer that will watch for changes in `Deployment` resources, we need to register handler
functions for add, update and delete events. This is done via the `informer.AddEventHandler` method:

```go
package main

import (
	"log"
	"os"
	"time"
	"os/signal"
	"context"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/dynamic/dynamicinformer"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/cache"
)

func main() {
	kubeConfig := os.Getenv("KUBECONFIG")
	
	var clusterConfig *rest.Config
	var err error
	if kubeConfig != "" {
		clusterConfig, err = clientcmd.BuildConfigFromFlags("", kubeConfig)
	} else {
		clusterConfig, err = rest.InClusterConfig()
	}
	if err != nil {
		log.Fatalln(err)
	}

	clusterClient, err := dynamic.NewForConfig(clusterConfig)
	if err != nil {
		log.Fatalln(err)
	}
	
	resource := schema.GroupVersionResource{Group:"apps", Version:"v1", Resource: "deployments"}
	factory := dynamicinformer.NewFilteredDynamicSharedInformerFactory(clusterClient, time.Minute, corev1.NamespaceAll, nil)
	informer := factory.ForResource(resource).Informer()
	
	informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			u := obj.(*unstructured.Unstructured)
        },
		UpdateFunc: func(oldObj, newObj interface{}) {},
		DeleteFunc: func(obj interface{}) {},
    })

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	
	informer.Run(ctx.Done())
}
```

Notice that for `AddFunc`, `UpdateFunc` and `DeleteFunc` that the parameters are passed as `interface{}`, because we're
using the `dynamicinformer` package, we can assume these are instances of `*unstructured.Unstructured` and safely cast them.

We're also creating a `context.Context` that is cancelled on an `os.Interrupt` signal. This allows us to prevent the application
from exiting until it receives an interrupt signal. Its `Done` channel is passed to `informer.Run`, to keep the informer
alive until execution is cancelled.

From here, your handling logic is your own, do what you want when resources are added, updated or changed. Further sections
in this post will cover additional considerations regarding cache syncing and using RBAC to give your `Pod` access to
the Kubernetes API.

## Cache Syncing

When an informer starts, it will build a cache of all resources it currently watches which is lost when the application
restarts. This means that on startup, each of your handler functions will be invoked as the initial state is built. If this
is not desirable for your use case, you can wait until the caches are synced before performing any updates using the
`cache.WaitForCacheSync` function:

```go
package main

import (
	"log"
	"os"
	"sync"
	"time"
	"os/signal"
	"context"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/dynamic/dynamicinformer"
	"k8s.io/apimachinery/pkg/runtime/schema"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/tools/cache"
)

func main() {
	kubeConfig := os.Getenv("KUBECONFIG")

	var clusterConfig *rest.Config
	var err error
	if kubeConfig != "" {
		clusterConfig, err = clientcmd.BuildConfigFromFlags("", kubeConfig)
	} else {
		clusterConfig, err = rest.InClusterConfig()
	}
	if err != nil {
		log.Fatalln(err)
	}

	clusterClient, err := dynamic.NewForConfig(clusterConfig)
	if err != nil {
		log.Fatalln(err)
	}

	resource := schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "deployments"}
	factory := dynamicinformer.NewFilteredDynamicSharedInformerFactory(clusterClient, time.Minute, corev1.NamespaceAll, nil)
	informer := factory.ForResource(resource).Informer()

	mux := &sync.RWMutex{}
	synced := false
	informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			mux.RLock()
			defer mux.RUnlock()
			if !synced {
				return
			}
			
			// Handler logic
		},
		UpdateFunc: func(oldObj, newObj interface{}) {
			mux.RLock()
			defer mux.RUnlock()
			if !synced {
				return
			}

			// Handler logic
		},
		DeleteFunc: func(obj interface{}) {
			mux.RLock()
			defer mux.RUnlock()
			if !synced {
				return
			}

			// Handler logic
		},
	})

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	go informer.Run(ctx.Done())
	
	isSynced := cache.WaitForCacheSync(ctx.Done(), informer.HasSynced)
	mux.Lock()
	synced = isSynced
	mux.Unlock()
	
	if !isSynced {
		log.Fatal("failed to sync")
    }
	
	<-ctx.Done()
}
```

In the code above, we use a boolean `synced` to indicate that the caches are finished syncing and that our handler functions
are only being invoked once the initial state of the watched resources has been built. We've had to make some modifications,
like starting the informer asynchronously using a `go` statement, as the caches will not start building until `informer.Run`
is called.

It may seem unintuitive at first, but we also don't directly assign the return value of `WaitForCacheSync` to the `synced`
variable within a mutex lock. This is because the handler functions are being invoked while the cache is syncing and will
effectively be queued. If we lock that mutex initially, the updates that occurred while the cache was syncing will still trigger
our handler functions. This means we need to only reassign `synced` once we're sure the cache sync is complete.

## RBAC

Finally, when running within a cluster, we're going to need to use RBAC to provide the `ServiceAccount` the appropriate
permissions to monitor resources of our choosing. This is done using the `Role`/`RoleBinding` resources (if you're handling
things at the namespace level) or the `ClusteRole`/`ClusterRoleBinding` resources (if you're handling things at the cluster
level). You can view full documentation for these resources [here](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

Let's create a `ServiceAccount`, `ClusterRole` and `ClusterRoleBinding` to match our code above. It will allow us to watch
all `Deployment` resources in all namespaces:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: myinformer
  namespace: mynamespace
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: deployment-informer
rules:
- apiGroups: ["apps/v1"]
  resources: ["deployments"]
  verbs: ["get", "watch", "list"]
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: read-secrets-global
subjects:
- kind: ServiceAccount
  name: myinformer
  namespace: mynamespace
roleRef:
  kind: ClusterRole
  name: deployment-informer
  apiGroup: rbac.authorization.k8s.io
```

When you deploy your application within the cluster, use the `serviceAccountName` field in the pod specification to
the `myinformer` one created above. This will provide the `Pod` with access to the Kubernetes API, specifically to perform
`get`, `list` and `watch` request on `Deployment` resources.

## Wrapping Up

Hopefully this post has given you enough insight into the world of Kubernetes informers to implement your own. As said
at the start, I used code like this to implement [Kollect](https://github.com/davidsbond/kollect), and it works as well
as you would expect.

## Links

* [https://github.com/davidsbond/kollect](https://github.com/davidsbond/kollect)
* [https://www.openpolicyagent.org](https://www.openpolicyagent.org)
* [https://blog.golang.org/using-go-modules](https://blog.golang.org/using-go-modules)
* [https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account)
* [https://kubernetes.io/docs/concepts/workloads/pods](https://kubernetes.io/docs/concepts/workloads/pods)
* [https://kubernetes.io/docs/reference/access-authn-authz/rbac](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
