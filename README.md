Undo/Redo, Versioning, Operational Transformation and Transactions for Meteor Collections
=========================================================================================


What does this package do?
--------------------------

This package provides four additional and closely related features to Meteor:

1. Transactions
2. Infinite-Level Undo/Redo
3. Automatic Conflict Resolution for Concurrent Distributed Transactions (aka "Operational
   Transformation", "Preservation of Intent and Causality")
4. Versioning of Collection Objects


What does this mean?

The package applies some magic to Meteor collections so they become versioned and transactional. This
means that you can package an arbitrary number of changes across an arbitrary number of collections and
collection objects into a single transaction that will either atomically succeed or fail.

Based on this transactional behavior, the package provides an infinite-level, client-specific undo/redo
stack so that you can undo (or redo) any previously executed transaction with an API call as simple as
`undo()` (or `redo()`).

Meteor's 'last-write-wins' default conflict resolution mechanism does not work well when you have many
users working on the same few objects. Conflicting changes will simply replace each other without trying
to intelligently guess how changes could be "merged" to better reflect the intent of collaborating users.

We replace this default behavior with fully automatic conflict resolution preserving causality and intent.
This is achieved with a technology that is equivalent to
"[Operational Transformation](https://en.wikipedia.org/wiki/Operational_transformation)" (OT), called
"[Commutative Replicated Data Types](http://hal.inria.fr/docs/00/44/59/75/PDF/icdcs09-treedoc.pdf)" (CRDT).
The net effect is that concurrent updates from different clients to the same collection object will not
overwrite each other but will be merged intelligently.

Versioning is already built into the functionality of the package and can be used in principle. We just do
not yet provide a high-level API to retrieve specific versions of a collection or an object. Every
versioned collection comes with a second "twin collection" that contains the whole version history of
all objects. You can have a look at the Mongo database and you'll see what I mean. We'll eventually
provide a public high-level API to access that collection more comfortably. But if you feel brave you can
already have a look at it and try to figure out how versioning is being implemented. Have a look
at [this inline comment](https://github.com/jerico-dev/meteor-versioning/blob/master/crdt.coffee#L39) which
will help you to better understand the data format.


Requirements
------------

This package requires Meteor 0.5.5 or later.


Installation
------------

The package can be installed with [Meteorite](https://github.com/oortcloud/meteorite/).

Type inside your application directory:

``` sh
$ mrt add versioning
```

Usage
-----

See the following sample code which works both, on the client and server. The example is in CoffeeScript for better readability.

``` coffeescript
# Meteor.tx points to the global transaction manager.
tx = Meteor.tx

# Meteor.tx.purgeLog() purges the transaction log.
# The transaction log is just for debugging right
# now. Later we'll use it to retrieve arbitrary past
# model snapshots. In this example we purge the
# log to make sure that prior tests won't be reflected
# in the log.
tx.purgeLog()

# Create a versioned collection. In this example
# we want to represent a directed graph with nodes
# and edges. Edges are saved as nested documents.
# This is to demonstrate that basic OT capabilities
# can be extended to nested subdocuments.
# If you are just versioning a key/value document
# with scalar values then you simply instantiate a
# versioned collection like this:
# myColl = new Meteor.Collection 'myColl', {versioned: true}
# In our example we use a more complex collection to
# demonstrate advanced features:
Nodes = new Meteor.Collection 'nodes',
  versioned: true
  props:
    edges: {type: '[{}]', locator: 'label'}

# This removes all objects from the versioned collection
# including all versioning information. Use this for
# testing or if you really want to start over!
Nodes.reset()

# Generate a test transaction.
initialNodes = [
    name: 'root',
    content: 'Root Node',
    position: { x: 500, y: 100 }
  ,
    name: 'child1',
    content: 'Child Node',
    position: { x: 650, y: 230 }
  ,
    name: 'child2',
    content: 'Child Node',
    position: { x: 350, y: 230 }
  ]
ids = []
for node in initialNodes
  # Meteor.Collection.insertOne() takes a single parameter:
  # the object to be inserted.
  newId = Nodes.insertOne node
  ids.push newId

# Call tx.commit() to actually execute the operations that you staged.
# Commit executes the currently staged operations and automatically
# starts a new transaction. You do not have to start transactions manually.
tx.commit()

for [label, from, to] in [['a', 0, 1], ['b', 0, 2]]
  # Use Meteor.Collection.setProperty() to update
  # your versioned objects.
  #
  # NB: Right now you cannot update several properties at once.
  #
  # The method takes three parameters:
  # 1) The ID of the object you want to change.
  # 2) The name of the property to be changed.
  # 3) The new value.
  #
  # NB: In the case of versioned collections (ordered sub-arrays or nested docs)
  # this actually adds a new element to the collection and does not replace
  # existing elements! In the case of scalar values, the prior value will be
  # replaced.
  Nodes.setProperty ids[from], 'edges', {label: label, to: ids[to]}

tx.commit()

# To roll back a running transaction just emit tx.rollback() and all
# operations you added since the last commit will be "forgotten".
# We don't do this here so that we can demonstrate undo/redo.

# Use Meteor's usual query API to retrieve objects from your versioned
# collection. Observers work normally, too:
allNodes = Nodes.find().fetch()

# To undo the last transaction, simply call:
tx.undo()

# This will undo the last transaction of the current client! (Or if you are
# on the server side then the last transaction committed by the server.) There
# currently is no global undo.
# Undo is multi-level. You can undo as many operations as you like.
# Our OT-algorithm should provide good conflict resolution defaults in case
# other clients have executed concurrent transactions since the undone
# transaction. Observe the state of your collection and tell me if you expected
# different behavior.
# Undoing a transaction will actually not really "roll back" the prior
# transaction but rather execute an opposite (or "inverse") transaction that
# undoes the effect of the prior transaction. This "insert-only" logic is
# necessary for our OT and undo/redo algorithms to work correctly.

# The effect of the last transaction has been undone and our sample object
# collection will no longer contain the 'edges' properties we inserted in
# the last transaction.
nodesWithoutEdges = Nodes.find().fetch()

# To redo the last undone transaction, call:
tx.redo()

# In our example, the edges of the graph have now been restored.
nodesWithEdges = Nodes.find().fetch()

# Redo is multi-level and works with a client-specific undo/redo history, too.
#
# NB: As soon as you commit a new transaction you'll loose your redo
# history (but not your undo history)! This is the usual behavior of
# redo in most programs I know of, so end users shouldn't be too surprised
# of that.
```


Publish/Subscribe
-----------------

`Meteor.publish()` and `Meteor.subscribe()` work normally with versioned
collections.


Security
--------

All changes to the versioned connection are packaged as transactions and
then funneled through an internal Meteor method. We currently do not check any
security validators (i.e. `Meteor.Collection.allow()/deny()`) in this method.

This means that setting allow/deny rules on a versioned collection will
NOT WORK right now. We'll fix this in a later version.


Cursors
-------

Cursors returned by calling `find()/findOne()` on a versioned collection will
work normally. This includes all sub-methods of a cursor, e.g. `forEach()/map()`,
observers, etc.


Latency Compensation
--------------------

Updates to versioned collections have built-in latency compensation. Changes to
versioned collections on the client will be simulated until the server returns
with an authoritative version of the collection.


API reference
-------------

### Meteor.tx

This is the transaction manager. It contains global functions to commit or roll
back transactions. It also provides the redo/undo feature.

Undo/redo histories are kept separately for all clients. This is the usual behavior
in collaborative systems and avoids that concurrent operations from other users can
be undone.

#### Meteor.tx.commit()

Call this to commit all operations queued since the last `commit()` call.

#### Meteor.tx.rollback()

Call this to roll back the current transaction and "forget" all operations
scheduled since the last `commit()` call.

#### Meteor.tx.undo()

Undo on the last transaction committed by this client (or server). The undo history
is infinite but it is kept in RAM and therefore will not survive a page reload or
server restart.

#### Meteor.tx.redo()

Redo the last undone transaction. The redo history contains all undone transactions
of the local client. It is kept in RAM, too, and will not survive a server restart
or page reload.

Committing a new transaction will purge the redo (but not the undo) stack.

#### Meteor.tx.purgeLog()

Call this to purge the internal transaction log.

The log is currently not actively used. It is great for debugging, though,
and to understand how this Meteor extension actually works.

Have a look at the "transactions" collection in Mongo.

I'm not currently providing a versioning API (i.e. "give me the exact
version of object X at time Y"). It is perfectly possible, however,
to reconstruct all intermediate states of every object from the transaction
log and this will probably be explicitly supported in the future.



### Meteor.Collection(name[, options])

The constructor of `Meteor.Collection` takes two arguments:

1. `name`: The collection name
2. `options` (optional): collection options.
   Please see the Meteor docs for an explanation
   of possible values. We'll only document the
   values added by the versioning smart package.
   The options parameter of Meteor.Collection now
   takes two additional options:
   * `versioned`: Set this to `true` if you'd like to
     instantiate a versioned collection.
   * `props` (optional): If you want to version nested
     documents or nested arrays then you have to
     provide a property specification. This is done
     with one entry per non-default property in the
     props option.
     The key of each entry is the name of the property
     to be specified. The value is an object that
     contains the following entries:
     - `type`: One of '[{}]' or '[*]'. The former
       represents a versioned list of subdocuments
       and the latter a versioned sub-array.
     - `locator` (optional): Only used for versioned
       sub-documents. This specifies the primary key
       of the sub-document list. It will be used to
       distinguish updates from insertions/deletions.
   See the "Usage" section above for an example.

If you are just versioning a key/value document
with scalar values then no property specification is
required:

``` javascript
myColl = new Meteor.Collection('myColl', {versioned: true});
```

NB: The usual mutators `insert()`, `update()` and `remove()`
will not work for a versioned collection and have been
hidden.

For the moment being the mutator API of a versioned
collection is quite different (and much uglier) than
the API of the usual Meteor collection types. We
implement a low-level API that doesn't allow for batch
operations. The only reason is that I don't need anything
more sophisticated myself and I don't have time
right now to implement more unless someone wants to
pay me for it. ;-) In the long term I'd like to implement
the complete MiniMongo API for versioned collections.
Feel free to step in with a pull request if you want
to work in that direction.

For queries you can use the usual Meteor `find()`/`findOne()`
API so you get all of Meteor's query flexibility,
observers, reactivity, etc. as with a normal collection.


#### Meteor.Collection.insertOne(document)

Arguments:

1. `document`: The object to insert to the collection.

Use this to insert an arbitrary new versioned document.

If the object contains sub-arrays or a list of nested
sub-documents then it must conform to the property
specification you provided for the collection!

If the object contains an `_id` property then this
will be used to save the object. Otherwise Meteor will
generate an ID for you.

The method will return the ID of the object.


#### Meteor.Collection.removeOne(id)

Arguments:

1. `id`: The ID of the document to remove.

This method will make the object corresponding to the given ID
"invisible". The object can be restored by calling `Meteor.tx.undo()`
later.


#### Meteor.Collection.setProperty(id, key, value)

Arguments:

1. `id`: The ID of the document to update.
2. `key`: The name of the object property to update.
3. `value`: The new (or additional) value.

This updates the existing object identified by the given ID.

The method behaves differently, depending on whether you are
updating a scalar property or a property that contains a
collection (an ordered array or a keyed list of sub-documents).

When you are updating a scalar value then the new value will
replace the existing value.

When you update a collection then the new value will be added
to the collection. Use `Meteor.Collection.unsetProperty()`
to actually remove an entry (or all entries) from a collection.


#### Meteor.Collection.unsetProperty(id, key[, locator])

Arguments:

1. `id`: The ID of the document to update.
2. `key`: The name of the object property to update.
3. `locator` (optional): When updating a property that
   contains a collection then use the locator to
   remove only a specific entry of the collection
   rather than the whole collection.

This updates the existing object identified by the given ID.

When no `locator` is given then the property (and in the case
of a collection all entries of the collection) will be marked
"invisible".

When you update a collection then you can give a `locator` to
only mark a specific element of the collection "invisible".

In the case of a versioned ordered array, the `locator` is the
index of the array element.

In the case of a versioned unordered (keyed) hash-list of
sub-documents the `locator` represents a value that will be
used to uniquely identify the sub-document to be "hidden".
Meteor looks for the given value in the property that
has been specified as the `locator` property. See the
`props` option of the constructor of `Meteor.Collection`
above.

Hidden elements can be made visible again by calling
`Meteor.tx.undo()`.


#### Meteor.Collection.reset()

Call this to reset the version history of the collection. This will
give you an empty collection without any undo/redo/versioning information.

Only do this if you really want to start over.


#### Meteor.Collection.find()/findOne()

Please consult the official Meteor documentation for a description
of these methods.


Known Limitations
-----------------

* Security (allow/deny) does not work for versioned collections.
* The current mutator API is too low-level. We should implement the full
  MiniMongo API.
* If you publish a versioned collection under a different name to the
  client (by manually publishing documents from it under a different
  collection name) then you won't be able to change that collection from
  the client directly. You'll have to change the original collection
  and wait for the changes to propagate.
* We should provide a high-level versioning API.


Package Dependencies
--------------------

The versioning package relies on a simple [logger](https://github.com/jerico-dev/meteor-logger)
and [i18n](https://github.com/jerico-dev/meteor-i18n) implementation. Both have
already been published as packages to the Atmosphere and will be automatically
installed when installing this package.

Have a look at the documentation of the two packages if you'd like to use them in your project.


Questions and Feature Requests
------------------------------

If you have feature requests or other feedback please write to jerico.dev@gmail.com.


Contributions
-------------

Contributions are welcome! Just make a pull request and I'll definitely check it out.
