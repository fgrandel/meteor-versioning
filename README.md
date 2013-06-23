# Undo/Redo, Improved Conflict Resolution and Transactions for Meteor Collections

**This package is no longer being actively maintained and has known incompatibilites
with newer versions of Meteor. Want to take it over? Fork and push to atmosphere...**

## What this package can do for you and what not

If you want to get your hands dirty immediately then move on to the
[Installation](#installation) and [Usage](#usage) sections.

Out-of-the-box Meteor uses field-level "last-write-wins" to handle concurrent
writing to a field in a document. This means that the last write on the field
overwrites all previous writes to that field. As Meteor currently uses MongoDB
in the backend there's also no support for transactions that span several
objects.

There are situations where this default behavior may not be what you want:
* Previously-written data will be completely lost when you change a document.
  It's not possible to undo changes and revert to a prior version of your
  document.
* This is most problematic when dealing with concurrent real-time updates to
  the same field where it's not usually intended that changes permanently
  overwrite each other.
* Due to the lack of transactions and Meteor's real-time, reactive behavior,
  clients may see inconsistent data which can cause flicker, difficult-to-debug
  errors or race conditions.

This package adds a few closely related features to Meteor to provide you
with additional options:

 1. infinite-level undo/redo
 2. (basic) transactions
 3. improved automatic conflict resolution for concurrent updates
 4. versioning of collection objects

What does this mean?

This package applies some magic to Meteor collections so they become versioned
across documents and collections.

With this package...
 * Every client has an infinite list of prior local changes. This means
   that a user can undo arbitrary locally initiated transactions even while
   other users make concurrent changes to the same fields in the same document.
 * You can package an arbitrary set of changes across any collections and
   collection objects into a single (mostly) atomic transaction.
 * You have an automatic server-side audit trail of all changes.

At the core of this package is a technology equivalent to "[Operational
Transformation](https://en.wikipedia.org/wiki/Operational_transformation)"
(OT), called "[Commutative Replicated Data
Types](http://hal.inria.fr/docs/00/44/59/75/PDF/icdcs09-treedoc.pdf)" (CRDT).
The net effect is that concurrent updates from different clients to the same
collection object will not overwrite each other but will be merged
intelligently on field level.

There are still a few important limitations to the package that may be relevant
to you. We have a full "Todo and Known Limitations" section below. For your
convenience I'll list the most important pros and cons right here:

|Features|Limitations|
|--------|-----------|
|Full support for Meteor publish/subscribe API|**No support for Meteor allow/deny**|
|Infinite undo/redo|No simple API to access specific versions|
|Improved automatic conflict-resolution on object level|No in-field versioning/OT yet, e.g. no OT-String type|
|Basic transaction support|Incomplete transactions will not be recovered after a server failure|
|Good integration with Meteor|No test suite|

As I'm doing this in my free time there's no specific timeline to remove the
limitations. But you can help yourself to remove them:

 1. Contributions are welcome! Feel free to provide a pull request. We also
    have some short introductory [developer documentation](HACKING.md). I'll
    help you with all my knowledge and ideas if you are interested in working
    as a team.
 2. I can provide exactly what YOU need when you contract me. If you donate
    then please accompany your donation with a comment or contact me by email
    (jerico.dev@gmail.com) to let me know what exactly I should work on for
    you.

<a href='http://www.pledgie.com/campaigns/19414'>
  <img alt='Click here to support Meteor versioning and make a donation at www.pledgie.com!'
    src='http://www.pledgie.com/campaigns/19414.png?skin_name=chrome' border='0' />
</a>


## Requirements

Meteor introduced compatibility breaking changes with it's version 0.5.7. Due
to this:
* Meteor 0.5.5 or 0.5.6: Use version 0.3.1 of this package. This version will
  no longer be developed.
* Meteor 0.5.7 and onwards: Use the most recent version of this package.


## Installation

The package can be installed with
[Meteorite](https://github.com/oortcloud/meteorite/).

Type inside your application directory:

``` sh
$ mrt add versioning
```

## Usage

To get you up and running quickly here a simple example:

``` javascript
var tx = Meteor.tx;

// Create a versioned collection.
var Todos = new Meteor.Collection('todos', {versioned: true});

// 1st transaction: insert an object into the collection.
var todoId = Todos.insertOne({
  title: 'Implement undo in my Meteor app',
  details: 'Learn the meteor-versioning package and see whether it does what I need.'
});
tx.commit();

// 2nd transaction: update the object.
Todos.setProperty(todoId, 'details', 'Doesn\'t seem to be difficult...');
tx.commit();
console.log(Todos.findOne()); // The content of the 'details' field is "Doesn't seem to be...".

// Undo the 2nd transaction.
tx.undo();
console.log(Todos.findOne()); // The 'details' field is now: "Learn the meteor-versioning package...".

// Redo the 2nd transaction.
tx.redo();
console.log(Todos.findOne()); // The content of the 'details' field is "Doesn't seem to be..." again.
```


The next example comes with in-depth comments and is more complex to give an
overview over the full functionality of the package. It should work both, on
the client and server. This example is in CoffeeScript for better readability.

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


## Publish/Subscribe

`Meteor.publish()` and `Meteor.subscribe()` work normally with versioned
collections.

When you un-/resubscribe from/to a collection then your local undo/redo history
will be purged as it would otherwise contain operations on objects that are
no longer available.


## Security

All changes to the versioned connection are packaged as transactions and
then funneled through an internal Meteor method. We currently do not check any
security validators (i.e. `Meteor.Collection.allow()/deny()`) in this method.

This means that setting allow/deny rules on a versioned collection will
NOT WORK right now. We'll fix this in a later version.


## Cursors

Cursors returned by calling `find()/findOne()` on a versioned collection will
work normally. This includes all sub-methods of a cursor, e.g. `forEach()/map()`,
observers, etc.


## Latency Compensation

Updates to versioned collections have built-in latency compensation. Changes to
versioned collections on the client will be simulated until the server returns
with an authoritative version of the collection.


## API reference

### Meteor.tx

This is the transaction manager. It contains global functions to commit or roll
back transactions. It also provides the redo/undo feature.

Undo/redo histories are kept separately for all clients. This is the usual
behavior in collaborative systems and avoids that concurrent operations from
other users can be undone.

#### Meteor.tx.commit()

Call this to commit all operations queued since the last `commit()` call.

#### Meteor.tx.rollback()

Call this to roll back the current transaction and "forget" all operations
scheduled since the last `commit()` call.

#### Meteor.tx.undo()

Undo on the last transaction committed by this client (or server). The undo
history is infinite but it is kept in RAM and therefore will not survive a page
reload or server restart.

#### Meteor.tx.redo()

Redo the last undone transaction. The redo history contains all undone
transactions of the local client. It is kept in RAM, too, and will not survive
a server restart or page reload.

Committing a new transaction will purge the redo (but not the undo) stack.

#### Meteor.tx.purgeLog()

Call this to purge the internal transaction log.

The log is currently not actively used. It is great for debugging, though,
and to understand how this Meteor extension actually works.

Have a look at the "transactions" collection in Mongo.

I'm not currently providing a versioning API (i.e. "give me the exact version
of object X at time Y"). It is perfectly possible, however, to reconstruct all
intermediate states of every object from the transaction log and this will
probably be explicitly supported in the future.



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

If you are just versioning a key/value document with scalar values then no
property specification is required:

``` javascript
myColl = new Meteor.Collection('myColl', {versioned: true});
```

NB: The usual mutators `insert()`, `update()` and `remove()` will not work for
a versioned collection and have been hidden.

For the moment being the mutator API of a versioned collection is quite
different (and much uglier) than the API of the usual Meteor collection types.
We implement a low-level API that doesn't allow for batch operations. The only
reason is that I don't need anything more sophisticated myself and I don't have
time right now to implement more unless someone wants to pay me for it. ;-) In
the long term I'd like to implement the complete MiniMongo API for versioned
collections.  Feel free to step in with a pull request if you want to work in
that direction.

For queries you can use the usual Meteor `find()`/`findOne()` API so you get
all of Meteor's query flexibility, observers, reactivity, etc. as with a normal
collection.


#### Meteor.Collection.insertOne(document)

Arguments:

1. `document`: The object to insert to the collection.

Use this to insert an arbitrary new versioned document.

If the object contains sub-arrays or a list of nested sub-documents then it
must conform to the property specification you provided for the collection!

If the object contains an `_id` property then this will be used to save the
object. Otherwise Meteor will generate an ID for you.

The method will return the ID of the object.


#### Meteor.Collection.removeOne(id)

Arguments:

1. `id`: The ID of the document to remove.

This method will make the object corresponding to the given ID "invisible". The
object can be restored by calling `Meteor.tx.undo()` later.


#### Meteor.Collection.setProperty(id, key, value)

Arguments:

1. `id`: The ID of the document to update.
2. `key`: The name of the object property to update.
3. `value`: The new (or additional) value.

This updates the existing object identified by the given ID.

The method behaves differently, depending on whether you are updating a scalar
property or a property that contains a collection (an ordered array or a keyed
list of sub-documents).

When you are updating a scalar value then the new value will replace the
existing value.

When you update a collection then the new value will be added to the
collection. Use `Meteor.Collection.unsetProperty()` to actually remove an entry
(or all entries) from a collection.


#### Meteor.Collection.unsetProperty(id, key[, locator])

Arguments:

1. `id`: The ID of the document to update.
2. `key`: The name of the object property to update.
3. `locator` (optional): When updating a property that
   contains a collection then use the locator to
   remove only a specific entry of the collection
   rather than the whole collection.

This updates the existing object identified by the given ID.

When no `locator` is given then the property (and in the case of a collection
all entries of the collection) will be marked "invisible".

When you update a collection then you can give a `locator` to only mark a
specific element of the collection "invisible".

In the case of a versioned ordered array, the `locator` is the index of the
array element.

In the case of a versioned unordered (keyed) hash-list of sub-documents the
`locator` represents a value that will be used to uniquely identify the
sub-document to be "hidden".  Meteor looks for the given value in the property
that has been specified as the `locator` property. See the `props` option of
the constructor of `Meteor.Collection` above.

Hidden elements can be made visible again by calling `Meteor.tx.undo()`.


#### Meteor.Collection.reset()

Call this to reset the version history of the collection. This will give you an
empty collection without any undo/redo/versioning information.

Only do this if you really want to start over.

NB: This method is only available on the server.


#### Meteor.Collection.find()/findOne()

Please consult the official Meteor documentation for a description of these
methods.


## Resource Usage

It won't come as a surprise that versioned collections consume considerably
more resources both, on the client and on the server, than a non-versioned
collection.

That being said I personally never found versioning to be a space or
performance bottleneck. Reactively updating the DOM in real time (e.g. via
Meteor's spark) is so much slower than keeping versioned objects that I never
perceived a difference.  I therefore stick to Donald Knuth's recommendation to
avoid premature optimization when it increases complexity.

If you perceive performance degradation due to object versioning let me know
and I'll try to help you find out where it comes from.



__Space:__

A versioned object needs to be mirrored in a separate collection with its full
version history for all fields plus considerable administrative information
necessary to track the causality of concurrent updates as well as all data
necessary for undo and redo.  Have a look at the '_[your collection name]Crdt'
collections in the Mongo DB for details.

You also have to be aware that space is even consumed when you delete an
object.  Otherwise prior versions could not be recovered.

In practice this is usually not a big problem as disk space is cheap and
objects will only be loaded into RAM when actually being used (i.e. in a query
or observer).

On the server side: The same rules apply as to normal Meteor collections with
the exception of deleted objects: While the snapshot version (latest version)
will be removed from RAM, the version mirror will be kept in RAM as long as it
is part of a published collection. This is necessary to enable undo on the
server.

On the client side: Space requirements on the client are considerably
optimized.  We only copy version information to the client for objects that are
actually being published to the client.

When you re-subscribe to a different selection of client objects then the RAM
necessary to hold prior versioned objects will also be released. This explains
why re-subscribing to a collection will invalidate the undo/redo history: You
loose version history locally when you subscribe to a different partition of
the collection. The full version history is nonetheless kept on disk, of
course.


__Time:__

Updating versioned objects is considerably slower than updating non-versioned
objects.

This is mainly due to the following additional processing steps:
 1. The transaction framework has a slight overhead over usual updates by
    handling abstract operations.
 2. Updating the internal representation of a versioned collections is
    considerably more complex than updating a non-versioned collection. We
    have to update both, the object snapshot as well as the versioned object
    mirror.
 3. Taking a snapshot from the versioned mirror consumes quite a few processor
    cycles and must be done whenever an object changes.
 4. Replicating versioned objects accross clients takes longer as more data
    needs to be transferred to the client. This is not a problem in practice
    as latency compensation comes up for this.


## Bugs

There are no known bugs but the package has not yet been thoroughly tested
across many platforms. If you encounter a bug let me know by posting an issue
to github.


## Known Limitations / Todos

* Security (allow/deny) does not work for versioned collections.
* The current mutator API is too low-level. We should implement the full
  MiniMongo API. We also should simplify property configuration (e.g.
  discover type by convention).
* We should provide a high-level versioning API. Versioning is already built
  into the functionality of the package and can be used in principle. We just
  do not yet provide a simple API to retrieve specific versions of a collection
  or an object. Every versioned collection comes with a second "twin collection"
  that contains the whole version history of all objects. You can have a look
  at the Mongo database and you'll see what I mean. Have a look at [this inline
  comment](https://github.com/jerico-dev/meteor-versioning/blob/master/crdt.coffee#L39)
  which will help you to better understand the data format.
* We should have a test suite.
* We should implement a versioned text type so that we can track
  and merge in-field changes for strings. This requires implementation
  of a treedoc balancing / treedoc OT protocol.
* There is no good abort() implementation yet if commiting a transaction
  hits a bug. Errors during commit should not occur unless you hit a bug.
  If this happens then your undo/redo stack will most probably be invalid
  and you cannot be sure that you have a consistent database. Please report
  all errors during commit and I'll fix them as quickly as possible.


## Package Dependencies

The versioning package relies on a simple
[logger](https://github.com/jerico-dev/meteor-logger) and
[i18n](https://github.com/jerico-dev/meteor-i18n) implementation. Both have
already been published as packages to the Atmosphere and will be automatically
installed when installing this package.

Have a look at the documentation of the two packages if you'd like to use them
in your project.


## Questions and Feature Requests

If you have feature requests or other feedback please write to
jerico.dev@gmail.com.


## Contributions

Contributions are welcome! Just make a pull request and I'll definitely check
it out.

If you don't know what to work on: Have a look at the "Known Limitations"
above.

For an introduction to hacking the package, see the [developer
documentation](HACKING.md).


## Credit

Thanks to Thomas Knight for his detailed and valuable feedback and contribution
to this documentation.
