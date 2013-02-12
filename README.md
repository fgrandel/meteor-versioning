Undo/Redo, Versioning, Operational Transformation and Transactions for Meteor Collections
=========================================================================================


Installation
------------

The package can be installed with [Meteorite](https://github.com/oortcloud/meteorite/).

Type inside your application directory:

``` sh
$ mrt add versioning
```

NB: Currently the package relies on the "autopublish" package. We'll change that with the next release!


Usage
-----

The package provides a special (virtual) collection type that you can use to manage versioned/transactional collections.

See the following sample code which works both, on the client and server. The example is in CoffeeScript for better readability.

``` coffeescript
# Meteor.tx points to the global transaction manager.
tx = Meteor.tx

# Meteor.tx.purgeLog() purges the transaction log.
# The transaction log is necessary if you want to
# re-establish a prior version of your collections.
# It's not beeing used for anything else currently.
# In this example we purge the log to make sure that
# prior tests won't be reflected in the log.
tx.purgeLog()

# Create a versioned collection. In this example
# we want to represent a directed graph with nodes
# and edges. Edges are saved as nested documents.
# This is to demonstrate that basic OT capabilities
# can be extended to nested subdocuments.
# Meteor.VersionedCollection takes two parameters:
# 1) The collection name
# 2) Optional: if you want to version nested documents
#    or nested arrays then you have to specify the
#    property. This is done with an options object that
#    contains two entries:
#    - type: One of '[{}]' and '[*]'. The former
#      represents a versioned list of subdocuments
#      and the latter a versioned sub-array.
#    - locator: Only used for versioned sub-documents.
#      This specifies the primary key of the sub-document
#      list. It will be used to distinguish updates from
#      insertions/deletions.
# If you are just versioning a simple key/value document
# with scalar values then the you simply instantiate a
# versioned collection like this:
# myColl = new Meteor.VersionedCollection 'myColl'
# In our example we use a more complex collection to
# demonstrate advanced features:
nodes = new Meteor.VersionedCollection 'nodes',
  edges: {type: '[{}]', locator: 'label'}

# For the moment being the mutator API of a versioned
# collection is quite different from the usual Meteor
# collection types. Right now, we implement a low-level
# API that doesn't allow for batch operations. The only
# reason for this is that I don't need something more
# sophisticated right now. Feel free to propose a higher
# level implementation, if you like. In principle I think
# that even "minimongo-level" abstraction would be possible.
# I just don't have time to implement this right now unless
# someone wants to pay me for it. ;-)
#
# Queries delegate to the usual Meteor find()/findOne()
# API so you get all of Meteor's flexibility for queries,
# observers, reactivity, etc. as with a normal collection.

# This removes all objects from the versioned collection
# including all versioning information. Use this for
# testing or if you really want to start over!
nodes.reset()

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
  # Meteor.VersionedCollection.insertOne() takes a single parameter:
  # the object to be inserted.
  newId = nodes.insertOne node
  ids.push newId
tx.commit()

for [label, from, to] in [['a', 0, 1], ['b', 0, 2]]
  # Use Meteor.VersionedCollection.setProperty() to update
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
  nodes.setProperty ids[from], 'edges', {label: label, to: ids[to]}

# Call tx.commit() to actually execute the operations that you staged.
# Commit executes the currently staged operations and automatically
# starts a new transaction. You do not have to start transactions manually.
tx.commit()

# To roll back a running transaction just emit tx.rollback() and all
# operations you added since the last commit will be "forgotten".

# Use Meteor's usual query API to retrieve objects from your versioned
# collection. Observers work normally, too:
allNodes = nodes.find().fetch()

# To undo the last transaction, simply call:
tx.undo()

# This will undo the last transaction of the current client! (Or if you are
# on the server side then the last transaction commited by the server.) There
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

# Now the addition of edges to our sample object collection will be undone
nodesWithoutEdges = nodes.find().fetch()

# To redo the last undone transaction, call:
tx.redo()

# In our example, the edges of the graph have been restored.
nodesWithEdges = nodes.find().fetch()

# Redo again works with a client-local undo/redo history.
# NB: As soon as you commit a new transaction you'll loose your redo
# history (but not your undo history)! This is the usual behavior of
# redo in most programs I know of, so end users shouldn't be too surprised
# of that.
```


API reference
-------------

### Meteor.tx

This is the transaction manager. It contains global functions to commit or roll
back transactions. It also provides the redo/undo feature.

Undo/redo histories are kept separately for all clients. This is the usual behavior
in collaborative systems and avoids that concurrent operations by other clients can
be undone.

#### Meteor.tx.commit()

Call this to commit all operations queued since the last commit() call.

#### Meteor.tx.rollback()

Call this to roll back the current transaction and "forget" all operations
scheduled since the last commit() call.

#### Meteor.tx.undo()

Undo on the last transaction commited by this client (or server). The undo history
is infinite but it is kept in RAM and therefore will not survive a page reload or
server restart.

#### Meteor.tx.redo()

Redo the last undone transaction. The redo history contains all undone transactions
of the local client. It is kept in RAM, too, and will not survive a restart/page reload.

Committing a new transaction will purge the redo (but not the undo) stack.

#### Meteor.tx.purgeLog()

Call this to purge the internal transaction log.

The log is currently not actively used. It is great for debugging, though,
and to understand how this Meteor extension actually works.

Have a look at the "transactions" collection in Mongo.

I'm not currently providing a versioning API (i.e. "give me the exact
version of object X at time Y"). It is perfectly possible, however,
to reconstruct all intermediate states of every object from the transaction
log and this will probably be explicitely supported in the future.



### Meteor.VersionedCollection(name[, propertySpec])

The constructor of `Meteor.VersionedCollection` takes two arguments:

1. `name`: The collection name
2. `propertySpec` (optional): If you want to version nested
   documents or nested arrays then you have to specify the
   property. This is done with an options object that
   contains two entries:
   - type: One of '[{}]' and '[*]'. The former
     represents a versioned list of subdocuments
     and the latter a versioned sub-array.
   - locator: Only used for versioned sub-documents.
     This specifies the primary key of the sub-document
     list. It will be used to distinguish updates from
     insertions/deletions.

If you are just versioning a key/value document
with scalar values then no property specification is
required and you simply instantiate a versioned
collection like a normal Meteor collection:

``` javascript
myColl = new Meteor.VersionedCollection('myColl')
```


#### Meteor.VersionedCollection.insertOne(object)

Arguments:
1. `object`: The object to insert to the collection.

Use this to insert an arbitrary new versioned object.

If the object contains sub-arrays or a list of nested
sub-documents then it must conform to the property
specification you provided for the object!

If the object contains an `_id` property then this
will be used to save the object (requires Meteor 0.5.5
or later!). Otherwise Meteor will generate an ID
for you.

The method will return the ID of the object.


#### Meteor.VersionedCollection.removeOne(id)

Arguments:
1. `id`: The ID of the object to remove.

This method will make the object corresponding to the given ID
"invisible". The object can be restored by calling `Meteor.tx.undo()`
later.


#### Meteor.VersionedCollection.setProperty(id, key, value)

Arguments:
1. `id`: The ID of the object to update.
2. `key`: The name of the object property to update.
3. `value`: The new (or additional) value.

This updates the existing object identified by the given ID.

The method behaves differently, depending on whether you are
updating a scalar property or a property that contains a
collection (an ordered array or a keyed list of sub-documents).

When you are updating a scalar value then the new value will
simply replace the existing value.

When you update a collection then the new value will be added
to the collection. Use `Meteor.VersionedCollection.unsetProperty()`
to actually remove an entry (or all entries) from a collection.


#### Meteor.VersionedCollection.unsetProperty(id, key[, locator])

Arguments:
1. `id`: The ID of the object to update.
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
`propertySpec` parameter of the constructor of
`Meteor.VersionedCollection` above.

Hidden elements can be made visible again by calling `Meteor.tx.undo()`.


#### Meteor.VersionedCollection.reset()

Call this to reset the version history of the collection. This will
give you an empty collection without any undo/redo/versioning information.

Only do this if you really want to start over.


#### Meteor.VersionedCollection.find()/findOne()

Please consult the documentation of `Meteor.Collection` for a description
of these methods.



Package Dependencies
--------------------

The versioning package relies on a simple [logger](https://github.com/jerico-dev/meteor-logger)
and [i18n](https://github.com/jerico-dev/meteor-i18n) implementation. Both have
already been published as packages to the Atmosphere and will be automatically
installed when installing this package.

Have a look at the documentation of the two packages if you'd like to
use them in your project.


Questions and Feature Requests
------------------------------

If you have feature requests or other feedback please write to jerico.dev@gmail.com.
