# Transaction-aware CRDT manager.
class Meteor._CrdtManager
  constructor: ->
    @collections = []

    getCrdtSnapshot = (collProps, serializedCrdt) ->
      crdt = new Meteor._CrdtDocument collProps, serializedCrdt
      crdt.snapshot()

  ##################
  # Public Methods #
  ##################
  addCollection: (name, props = {}) ->
    # Create the public snapshot version
    # of the managed collection
    snapshotColl = new Meteor.Collection name
    # Create the non-public CRDT version
    # of managed collections.
    crdtColl = new Meteor.Collection name + 'Crdts'
    if Meteor.isServer then crdtColl._ensureIndex crdtId: 1
    @collections[name] =
      snapshot: snapshotColl
      crdts: crdtColl
      props: props
    snapshotColl

  resetCollection: (name) ->
    if @collections[name]? and Meteor.isServer
      @collections[name].snapshot.remove {}
      @collections[name].crdts.remove {}
      true
    else
      false

  findCrdt: (name, crdtId) ->
    @collections[name].crdts.findOne crdtId: crdtId


  #######################
  # Transaction Support #
  #######################
  updatedCrdts: undefined

  txRunning: -> @updatedCrdts?

  txStart: ->
    console.assert not @txRunning(),
      'Trying to start an already running transaction.'
    @updatedCrdts = {}
    true

  txCommit: ->
    console.assert @txRunning(),
      'Trying to commit a non-existent transaction.'
    for mongoId, collName of @updatedCrdts
      # Find the updated CRDT.
      {snapshot: snapshotColl, crdts: crdtColl, props: crdtProps} =
        @collections[collName]
      serializedCrdt = crdtColl.findOne _id: mongoId
      console.assert serializedCrdt?
      crdt = new Meteor._CrdtDocument crdtProps, serializedCrdt
      crdtId = crdt.crdtId

      # Make a new snapshot of the updated CRDT.
      newSnapshot = crdt.snapshot()

      # Find the previous snapshot in the snapshot collection.
      oldSnapshot = snapshotColl.findOne _id: crdtId
      # Addition: If a previous snapshot does not exist then add a new one.
      if newSnapshot? and not oldSnapshot?
        snapshotColl.insert newSnapshot

      # Update: If a previous snapshot exists then update.
      if newSnapshot? and oldSnapshot?
        snapshotColl.update {_id: crdtId}, newSnapshot

      # Delete: If the new snapshot is 'null' then delete.
      if oldSnapshot? and not newSnapshot?
        snapshotColl.remove _id: crdtId
    @updatedCrdts = undefined
    true

  txAbort: ->
    @updatedCrdts = undefined


  ##############
  # Operations #
  ##############
  # Add an object to the collection.
  # args:
  #   object: the key/value pairs to create
  insertObject: (collection, crdtId, args, clock) ->
    # Check preconditions.
    console.assert @txRunning(),
      'Trying to execute operation "crdts.insertObject" outside a transaction.'

    # Does the object already exist (=re-insert)?
    serializedCrdt = @findCrdt(collection, crdtId)
    if serializedCrdt?
      unless serializedCrdt.deleted
        Meteor.log.throw 'crdt.tryingToUndeleteVisibleCrdt',
          {collection: collection, crdtId: crdtId}
      # We are actually un-deleting an existing object (happens on redo).
      # Mark the object as 'undeleted' which will make it publicly
      # visible again.
      @collections[collection].crdts.update {crdtId: crdtId},
        {$set: {deleted: false, clock: clock}}
      mongoId = serializedCrdt._id
    else
      # Create a new CRDT.
      crdt = new Meteor._CrdtDocument @collections[collection].props
      crdt.crdtId = crdtId
      crdt.clock = clock
      for key, value of args.object
        if _.isArray value
          for entry in value
            crdt.append {key: key, value: entry}
        else
          crdt.append {key: key, value: value}
      mongoId = @collections[collection].crdts.insert crdt.serialize()

    # Remember the inserted/undeleted CRDT for txCommit.
    @updatedCrdts[mongoId] = collection
    crdtId

  # Marks an object as deleted (i.e. makes it publicly invisible).
  # args: empty
  removeObject: (collection, crdtId, args, clock) ->
    # Check preconditions
    console.assert @txRunning(),
      'Trying to execute operation "crdts.removeObject" outside a transaction.'
    serializedCrdt = @findCrdt(collection, crdtId)
    unless serializedCrdt?
      Meteor.log.throw 'crdt.tryingToDeleteNonexistentCrdt',
        {collection: collection, crdtId: crdtId}

    if serializedCrdt.deleted
      Meteor.log.throw 'crdt.tryingToDeleteCrdtTwice',
        {collection: collection, crdtId: crdtId}


    # Mark the object as 'deleted' which will hide it from
    # the public collection.
    @collections[collection].crdts.update {crdtId: crdtId},
      {$set: {deleted: true, clock: clock}}

    # Remember the changed CRDT for txCommit.
    @updatedCrdts[serializedCrdt._id] = collection
    crdtId

  # Add or update a key/value pair.
  # args:
  #   key, value: the key/value pair to change
  insertProperty: (collection, crdtId, args, clock) ->
    # Check preconditions
    console.assert @txRunning(),
      'Trying to execute operation "crdts.insertProperty" outside ' +
      'a transaction.'
    serializedCrdt = @findCrdt(collection, crdtId)
    unless serializedCrdt?
      Meteor.log.throw 'crdt.tryingToInsertValueIntoNonexistentCrdt',
        {key: args.key, collection: collection, crdtId: crdtId}

    # TODO: Check that the field exists for the node type.
    # TODO: Check that the field value is valid based on the field type.

    # Append the new key/value pair to the property list of the CRDT.
    crdt = new Meteor._CrdtDocument @collections[collection].props,
      serializedCrdt
    index = crdt.append {key: args.key, value: args.value}
    @collections[collection].crdts.update {crdtId: crdtId},
      {$set: {properties: crdt.serialize().properties, clock: clock}}

    # Remember the changed CRDT for txCommit.
    @updatedCrdts[serializedCrdt._id] = collection
    index

  # Marks a key/value pair as deleted (i.e. makes it publicly invisible).
  # args:
  #   key: the key of the property to be deleted
  #   locator:
  #     - if the property has type '[{}]' (subdocs) then
  #       the value of the subkey of the property to be deleted
  #     - if the property has type '[*]' (array) then
  #       the position of the value to be deleted
  removeProperty: (collection, crdtId, args, clock) ->
    # Determine the locator (if any)
    locator = undefined
    if args.locator? then locator = args.locator

    # Check preconditions
    console.assert @txRunning(), 'Trying to execute operation ' +
      '"crdts.removeProperty" outside a transaction.'
    serializedCrdt = @findCrdt(collection, crdtId)
    unless serializedCrdt?
      Meteor.log.throw 'crdt.tryingToDeleteValueFromNonexistentCrdt', {
          key: args.key, locator: locator,
          collection: collection, crdtId: crdtId
        }

    crdt = new Meteor._CrdtDocument @collections[collection].props,
      serializedCrdt

    # Delete the key/value pair at the given position.
    deletedIndices = crdt.delete args.key, locator
    @collections[collection].crdts.update {crdtId: crdtId},
      {$set: {properties: crdt.serialize().properties, clock: clock}}

    # Remember the changed CRDT for txCommit.
    @updatedCrdts[serializedCrdt._id] = collection
    deletedIndices

  # Inverse operation support.
  # args:
  #   op: the name of the operation to reverse
  #   args: the original arguments
  #   result: the original result
  inverse: (collection, crdtId, args, clock) ->
    {op: origOp, args: origArgs, result: origResult} = args

    switch origOp
      when 'insertObject'
        # The inverse of 'insertObject' is 'removeObject'
        @removeObject collection, crdtId, {}, clock

      when 'removeObject'
        # To invert 'removeObject' we set the 'delete' flag
        # of the removed (hidden) object back to 'false'.

        # Check preconditions
        console.assert @txRunning(),
          'Trying to execute operation "crdts.inverse(removeObject)" outside ' +
          'a transaction.'
        serializedCrdt = @findCrdt(collection, crdtId)
        unless serializedCrdt?
          Meteor.log.throw 'crdt.tryingToUndeleteNonexistentCrdt',
            {collection: collection, crdtId: crdtId}
        unless serializedCrdt.deleted
          # This may happen when two sites delete exactly the
          # same crdt concurrently. As this is not probable we
          # provide a warning as this may point to an error.
          Meteor.log.warning 'crdt.tryingToUndeleteVisibleCrdt',
            {collection: collection, crdtId: crdtId}

        # Mark the object as 'undeleted' which will make it
        # publicly visible again.
        @collections[collection].crdts.update {crdtId: crdtId},
          {$set: {deleted: false, clock: clock}}

        # Remember the changed CRDT for txCommit.
        @updatedCrdts[serializedCrdt._id] = collection
        true

      when 'insertProperty'
        # To invert 'insertProperty' we'll hide the inserted property entry.

        # Check preconditions
        console.assert @txRunning(),
          'Trying to execute operation "crdts.inverse(insertProperty)" ' +
          'outside a transaction.'
        serializedCrdt = @findCrdt(collection, crdtId)
        unless serializedCrdt?
          Meteor.log.throw 'crdt.tryingToDeleteValueFromNonexistentCrdt', {
              key: origArgs.key, locator: origResult,
              collection: collection, crdtId: crdtId
            }
        crdt = new Meteor._CrdtDocument @collections[collection].props,
          serializedCrdt

        # Delete the key/value pair with the index returned from the
        # original operation.
        deletedIndex = crdt.deleteIndex origResult, origArgs.key
        @collections[collection].crdts.update {crdtId: crdtId},
          {$set: {properties: crdt.serialize().properties, clock: clock}}

        # Remember the changed CRDT for txCommit.
        @updatedCrdts[serializedCrdt._id] = collection
        deletedIndex

      when 'removeProperty'
        # To invert 'removedProperty' we set the 'delete' flag
        # of the removed property entries back to 'false'

        # Check preconditions
        console.assert @txRunning(),
          'Trying to execute operation "crdts.inverse(removeProperty)" ' +
          'outside a transaction.'
        serializedCrdt = @findCrdt(collection, crdtId)
        unless serializedCrdt?
          Meteor.log.throw 'crdt.tryingToUndeleteValueFromNonexistentCrdt', {
              key: origArgs.key, locator: origResult[0]
              collection: collection, crdtId: crdtId
            }
        crdt = new Meteor._CrdtDocument @collections[collection].props,
          serializedCrdt

        # Undelete the key/value pair(s) with indices returned
        # from the original operation.
        undeletedIndices =
          for deletedIndex in origResult
            crdt.undeleteIndex deletedIndex, origArgs.key
        @collections[collection].crdts.update {crdtId: crdtId},
          {$set: {properties: crdt.serialize().properties, clock: clock}}

        # Remember the changed CRDT for txCommit.
        @updatedCrdts[serializedCrdt._id] = collection
        undeletedIndices

      else
        # We cannot invert the given operation.
        Meteor.log.throw 'crdt.cannotInvert', op: origOp


# Singleton.
Meteor._CrdtManager = new Meteor._CrdtManager

# Shortcut to create a new managed CRDT collection.
class Meteor.VersionedCollection
  constructor: (@name, props={}) ->
    @tx = Meteor.tx
    snapshot = Meteor._CrdtManager.addCollection @name, props

    # Wrap read-only snapshot methods.
    _.each ['find', 'findOne'], (method) =>
      @[method] = ->
        args = _.toArray(arguments)
        snapshot[method].apply(snapshot, args)

    # The server may reset the collections.
    if Meteor.isServer
      @reset = -> Meteor._CrdtManager.resetCollection name

  insertOne: (object) ->
    if object._id?
      id = object._id
      object._id = undefined
    else
      id = Meteor.uuid()
    @tx._addOperation
      op: 'insertObject'
      collection: @name
      crdtId: id
      args:
        object: object
    id

  removeOne: (id) ->
    @tx._addOperation
      op: 'removeObject'
      collection: @name
      crdtId: id
    id

  setProperty: (id, key, value) ->
    @tx._addOperation
      op: 'insertProperty'
      collection: @name
      crdtId: id
      args:
        key: key
        value: value
    id

  unsetProperty: (id, key, locator = undefined) ->
    args = key: key
    if locator? then args.locator = locator
    @tx._addOperation
      op: 'removeProperty'
      collection: @name
      crdtId: id
      args: args
    id
