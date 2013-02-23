# Patch the original collection to support versioning.
OriginalCollection = Meteor.Collection
class Meteor.Collection extends OriginalCollection
  _versioned: false

  constructor: (name, options = {}) ->
    super name, options

    # If this is not a versioned collection then return.
    @_versioned = if options.versioned? then options.versioned else false
    return @ unless @_versioned

    # If this is a versioned collection then add our own magic...
    @_defineOperations()

    # Create the non-public CRDT version of managed collections.
    @_crdts = new OriginalCollection "_#{name}Crdts",
      _preventAutopublish: true
    if Meteor.isServer then @_crdts._ensureIndex crdtId: 1

    @_propSpec = if options.props? then options.props else {}

    # Hide normal mutators and validators which don't work
    # (or shouldn't be accessed directly) in versioned collections.
    _.each ['insert', 'update', 'remove', 'allow', 'deny'],
      (method) =>
        @["_#{method}"] = @[method]
        delete @[method]

    # Register this collection with the transaction manager.
    @_tx = Meteor.tx
    @_tx._addCollection @

    # Whenever CRDTs are removed (i.e. when a subscription
    # changes or is stopped) we have to purge the undo/redo
    # stack as it will contain objects that are no longer
    # available.
    @_crdts.find().observe
      removed: (old) -> Meteor.tx._purgeUndoRedo()


  ##################
  # Public Methods #
  ##################
  # Insert our own mutators.
  insertOne: (object) ->
    if object._id?
      id = object._id
      delete object._id
    else
      id = @_makeNewID()
    @_tx._addOperation
      op: 'insertObject'
      collection: @_name
      crdtId: id
      args:
        object: object
        id: @_makeNewID()
    id

  removeOne: (id) ->
    @_tx._addOperation
      op: 'removeObject'
      collection: @_name
      crdtId: id
    id

  setProperty: (id, key, value) ->
    @_tx._addOperation
      op: 'insertProperty'
      collection: @_name
      crdtId: id
      args:
        key: key
        value: value
    id

  unsetProperty: (id, key, locator = null) ->
    args = key: key
    if locator? then args.locator = locator
    @_tx._addOperation
      op: 'removeProperty'
      collection: @_name
      crdtId: id
      args: args
    id

  #######################
  # Transaction Support #
  #######################
  _getCrdt: (crdtId) ->
    serializedCrdt = @_crdts.findOne _crdtId: crdtId
    if serializedCrdt?
      new Meteor._CrdtDocument @_propSpec, serializedCrdt
    else
      undefined

  # Allocate transaction-specific indexes per CRDT and
  # property.
  _getCurrentIndex: (crdt, key) ->
    idxs = Meteor._ensure @_propertyIdxs, crdt.id
    idxs[key] = crdt.getNextIndex key unless idxs[key]?
    idxs[key]

  _txRunning: -> @_updatedCrdts?

  _txStart: ->
    console.assert not @_txRunning(),
      'Trying to start an already running transaction.'
    @_updatedCrdts = []

    # Make sure that we allocate new property indexes
    # for this transaction.
    @_propertyIdxs = {}
    true

  _txCommit: ->
    console.assert @_txRunning(),
      'Trying to commit a non-existent transaction.'
    for mongoId in @_updatedCrdts
      # Find the updated CRDT.
      serializedCrdt = @_crdts.findOne _id: mongoId
      console.assert serializedCrdt?
      crdt = new Meteor._CrdtDocument @_propSpec, serializedCrdt
      crdtId = crdt.crdtId

      # Make a new snapshot of the updated CRDT.
      newSnapshot = crdt.snapshot()

      # Find the previous snapshot in the snapshot collection.
      oldSnapshot = @findOne _id: crdtId
      # Addition: If a previous snapshot does not exist then add a new one.
      if newSnapshot? and not oldSnapshot?
        @_insert newSnapshot

      # Update: If a previous snapshot exists then update.
      if newSnapshot? and oldSnapshot?
        @_update {_id: crdtId}, newSnapshot

      # Delete: If the new snapshot is 'null' then delete.
      if oldSnapshot? and not newSnapshot?
        @_remove _id: crdtId
    @_updatedCrdts = undefined
    true

  _txAbort: ->
    @_updatedCrdts = undefined


  ##############
  # Operations #
  ##############
  _defineOperations: ->
    @_ops =
      # Add an object to the collection.
      # args:
      #   object: the key/value pairs to create
      #   id: a unique ID for the internal CRDT object.
      #       NB: This must be set when generating the
      #       operation so that we get the same ID for
      #       the client simulation and the server side.
      #       Otherwise we'd get false removed/added events
      #       on the client when the server returns.
      insertObject: (crdtId, args, clock, site) =>
        # Check preconditions.
        console.assert @_txRunning(),
          'Trying to execute operation "insertObject" outside a transaction.'

        # Does the object already exist (=re-insert)?
        crdt = @_getCrdt(crdtId)
        if crdt?
          unless crdt.deleted
            Meteor.log.throw 'crdt.tryingToUndeleteVisibleCrdt',
              {collection: @_name, crdtId: crdtId}
          # We are actually un-deleting an existing object (happens on redo).
          # Mark the object as 'undeleted' which will make it publicly
          # visible again.
          @_crdts.update {_id: crdt.id},
            {$set: {_deleted: false, _clock: clock}}
          mongoId = crdt.id
        else
          # Create a new CRDT.
          crdt = new Meteor._CrdtDocument @_propSpec
          crdt.id = args.id
          crdt.crdtId = crdtId
          crdt.clock = clock
          for key, value of args.object
            index = @_getCurrentIndex(crdt, key)
            if _.isArray value
              for entry in value
                crdt.insertAtIndex key, entry, index, site
            else
              crdt.insertAtIndex key, value, index, site
          serializedCrdt = crdt.serialize()
          mongoId = @_crdts.insert serializedCrdt

        # Remember the inserted/undeleted CRDT for txCommit.
        @_updatedCrdts.push mongoId
        crdtId

      # Marks an object as deleted (i.e. makes it publicly invisible).
      # args: empty
      removeObject: (crdtId, args, clock, site) =>
        # Check preconditions
        console.assert @_txRunning(),
          'Trying to execute operation "removeObject" outside a transaction.'

        crdt = @_getCrdt(crdtId)
        unless crdt?
          Meteor.log.throw 'crdt.tryingToDeleteNonexistentCrdt',
            {collection: @_name, crdtId: crdtId}

        if crdt.deleted
          Meteor.log.throw 'crdt.tryingToDeleteCrdtTwice',
            {collection: @_name, crdtId: crdtId}


        # Mark the object as 'deleted' which will hide it from
        # the public collection.
        @_crdts.update {_id: crdt.id},
          {$set: {_deleted: true, _clock: clock}}

        # Remember the changed CRDT for txCommit.
        @_updatedCrdts.push crdt.id
        crdtId

      # Add or update a key/value pair.
      # args:
      #   key, value: the key/value pair to change
      insertProperty: (crdtId, args, clock, site) =>
        # Check preconditions
        console.assert @_txRunning(),
          'Trying to execute operation "insertProperty" outside a transaction.'

        crdt = @_getCrdt(crdtId)
        unless crdt?
          Meteor.log.throw 'crdt.tryingToInsertValueIntoNonexistentCrdt',
            {key: args.key, collection: @_name, crdtId: crdtId}

        # TODO: Check that the field exists for the node type.
        # TODO: Check that the field value is valid based on the field type.

        # Append the new key/value pair to the property list of the CRDT.
        index = @_getCurrentIndex(crdt, args.key)
        position = crdt.insertAtIndex args.key, args.value, index, site
        changedProps = _clock: clock
        changedProps[args.key] = crdt.serialize()[args.key]
        @_crdts.update {_id: crdt.id}, {$set: changedProps}

        # Remember the changed CRDT for txCommit.
        @_updatedCrdts.push crdt.id
        position

      # Marks a key/value pair as deleted (i.e. makes it publicly invisible).
      # args:
      #   key: the key of the property to be deleted
      #   locator:
      #     - if the property has type '[{}]' (subdocs) then
      #       the value of the subkey of the property to be deleted
      #     - if the property has type '[*]' (array) then
      #       the position of the value to be deleted
      removeProperty: (crdtId, args, clock, site) =>
        # Determine the locator (if any)
        locator = null
        if args.locator? then locator = args.locator

        # Check preconditions
        console.assert @_txRunning(),
          'Trying to execute operation "removeProperty" outside a transaction.'

        crdt = @_getCrdt(crdtId)
        unless crdt?
          Meteor.log.throw 'crdt.tryingToDeleteValueFromNonexistentCrdt',
            key: args.key
            locator: locator
            collection: @_name
            crdtId: crdtId

        # Delete the key/value pair at the given position.
        deletedIndices = crdt.delete args.key, locator
        changedProps = _clock: clock
        changedProps[args.key] = crdt.serialize()[args.key]
        @_crdts.update {_id: crdt.id}, {$set: changedProps}

        # Remember the changed CRDT for txCommit.
        @_updatedCrdts.push crdt.id
        deletedIndices

      # Inverse operation support.
      # args:
      #   op: the name of the operation to reverse
      #   args: the original arguments
      #   result: the original result
      inverse: (crdtId, args, clock, site) =>
        {op: origOp, args: origArgs, result: origResult} = args

        switch origOp
          when 'insertObject'
            # The inverse of 'insertObject' is 'removeObject'
            @_ops.removeObject crdtId, {}, clock, site

          when 'removeObject'
            # To invert 'removeObject' we set the 'delete' flag
            # of the removed (hidden) object back to 'false'.

            # Check preconditions
            console.assert @_txRunning(), 'Trying to execute operation ' +
              '"inverse(removeObject)" outside a transaction.'

            crdt = @_getCrdt(crdtId)
            unless crdt?
              Meteor.log.throw 'crdt.tryingToUndeleteNonexistentCrdt',
                {collection: @_name, crdtId: crdtId}
            unless crdt.deleted
              # This may happen when two sites delete exactly the
              # same crdt concurrently. As this is not probable we
              # provide a warning as this may point to an error.
              Meteor.log.warning 'crdt.tryingToUndeleteVisibleCrdt',
                {collection: @_name, crdtId: crdtId}

            # Mark the object as 'undeleted' which will make it
            # publicly visible again.
            @_crdts.update {_id: crdt.id},
              {$set: {_deleted: false, _clock: clock}}

            # Remember the changed CRDT for txCommit.
            @_updatedCrdts.push crdt.id
            true

          when 'insertProperty'
            # To invert 'insertProperty' we'll hide the inserted
            # property entry.

            # Check preconditions
            console.assert @_txRunning(), 'Trying to execute operation ' +
              '"inverse(insertProperty)" outside a transaction.'

            crdt = @_getCrdt(crdtId)
            unless crdt?
              Meteor.log.throw 'crdt.tryingToDeleteValueFromNonexistentCrdt',
                key: origArgs.key
                locator: origResult
                collection: @_name
                crdtId: crdtId

            # Delete the key/value pair with the index returned from the
            # original operation.
            [origIndex, origSite, origChange] = origResult
            deletedIndex = crdt.deleteIndex origArgs.key,
              origIndex, origSite, origChange
            changedProps = _clock: clock
            changedProps[origArgs.key] = crdt.serialize()[origArgs.key]
            @_crdts.update {_id: crdt.id}, {$set: changedProps}

            # Remember the changed CRDT for txCommit.
            @_updatedCrdts.push crdt.id
            deletedIndex

          when 'removeProperty'
            # To invert 'removedProperty' we set the 'delete' flag
            # of the removed property entries back to 'false'

            # Check preconditions
            console.assert @_txRunning(), 'Trying to execute operation ' +
             '"inverse(removeProperty)" outside a transaction.'

            crdt = @_getCrdt(crdtId)
            unless crdt?
              Meteor.log.throw 'crdt.tryingToUndeleteValueFromNonexistentCrdt',
                key: origArgs.key
                locator: origResult[0]
                collection: @_name
                crdtId: crdtId

            # Undelete the key/value pair(s) with indices returned
            # from the original operation.
            undeletedIndices =
              for [origIndex, origSite, origChange] in origResult
                crdt.undeleteIndex origArgs.key,
                  origIndex, origSite, origChange
            changedProps = _clock: clock
            changedProps[origArgs.key] = crdt.serialize()[origArgs.key]
            @_crdts.update {_id: crdt.id}, {$set: changedProps}

            # Remember the changed CRDT for txCommit.
            @_updatedCrdts.push crdt.id
            undeletedIndices

          else
            # We cannot invert the given operation.
            Meteor.log.throw 'crdt.cannotInvert', op: origOp


if Meteor.isServer
  # The server may reset the collections.
  Meteor.Collection::reset = ->
    @remove {}
    if @_versioned then @_crdts.remove {}
    true

  # Patch the live subscription to automatically publish the CRDT version
  # together with the snapshot version.
  OriginalLivedataSubscription = Meteor._LivedataSubscription
  class Meteor._LivedataSubscription extends OriginalLivedataSubscription
    _removingAllDocs: false

    _synchronizeCrdt: (collectionName, id, fields = {}) ->
      # If the collection is versioned then publish not only
      # the snapshot value but also its corresponding CRDT.
      coll = Meteor.tx._getCollection(collectionName)
      return unless coll?
      currentCrdt = (coll._crdts.findOne _crdtId: id) ? {}
      unless currentCrdt?
        console.assert false, 'Found snapshot without corresponding CRDT'
        return
      # We must first establish all keys that maybe have
      # to be published.
      # 1) Internal keys
      internalKeys = ['_id', '_crdtId', '_clock', '_deleted']
      # 2) Keys that that changed.
      changedKeys = _.keys fields
      # 3) Keys that have been published previously.
      # NB: We never remove previously published CRDT keys from the
      # client, otherwise local undo simulation does not work. This
      # is part of our insert-only CRDT policy. Probably we should
      # implement some garbage collection method on the client which
      # cleans up the CRDT collection when the undo stack is being
      # emptied on the client.
      strId = @_idFilter.idStringify(currentCrdt._id)
      collView = @_session.collectionViews[coll._crdts._name]
      if collView? then docView = collView.documents[strId]
      added = if docView then false else true
      crdtSnapshot = if added then {} else docView.getFields()
      publishedKeys = _.keys crdtSnapshot
      # Collect all fields in this CRDT that should be published.
      crdtKeys = _.union internalKeys, changedKeys, publishedKeys
      crdtFields = {}
      for crdtKey in crdtKeys
        # Only send changed values over the wire.
        unless _.isEqual(currentCrdt[crdtKey], crdtSnapshot[crdtKey])
          crdtFields[crdtKey] = currentCrdt[crdtKey]
      [coll._crdts._name, currentCrdt._id, crdtFields, added]

    added: (collectionName, id, fields) ->
      crdtSync = @_synchronizeCrdt(collectionName, id, fields)
      if _.isArray(crdtSync)
        [crdtColl, crdtId, crdtFields, added] = crdtSync
        if added
          super crdtColl, crdtId, crdtFields
        else
          @changed crdtColl, crdtId, crdtFields, false
      super collectionName, id, fields

    changed: (collectionName, id, fields, syncCrdt = true) ->
      # There's no nice way in coffeescript to access the
      # superclass implementation, yet.
      # See https://github.com/jashkenas/coffee-script/issues/1606
      # So let's work around this for now.
      if syncCrdt
        crdtSync = @_synchronizeCrdt(collectionName, id, fields)
        if _.isArray(crdtSync)
          [crdtColl, crdtId, crdtFields, added] = crdtSync
          console.assert not added, 'Trying to update a non-existent CRDT'
          super crdtColl, crdtId, crdtFields
      super collectionName, id, fields

    removed: (collectionName, id) ->
      # CRDTs may not be removed as long as
      # we subscribe to the corresponding snapshot.
      isCrdtColl = /_\w+Crdts/.test(collectionName)
      console.assert not isCrdtColl or @_removingAllDocs
      unless @_removingAllDocs
        crdtSync = @_synchronizeCrdt(collectionName, id)
        if _.isArray(crdtSync)
          [crdtColl, crdtId, crdtFields, added] = crdtSync
          console.assert not added, 'Trying to delete a non-existent CRDT'
          @changed crdtColl, crdtId, crdtFields, false
      super collectionName, id

    _removeAllDocuments: ->
      # This is called when the subscription ends. In this case we
      # allow delete messages for CRDTs to reach the client.
      @_removingAllDocs = true
      super()
