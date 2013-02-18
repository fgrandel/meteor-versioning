# Patch the original collection to support versioning.
OriginalCollection = Meteor.Collection
class Meteor.Collection extends OriginalCollection
  constructor: (name, options = {}) ->
    super name, options

    # If this is not a versioned collection then return.
    @_versioned = if options.versioned? then options.versioned else false
    return @ unless @_versioned

    # If this is a versioned collection then add our own magic...

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

    ##################
    # Public Methods #
    ##################
    # Insert our own mutators. We don't do this in the
    # prototype to avoid polluting the normal collection
    # implementation.
    @insertOne = (object) ->
      if object._id?
        id = object._id
        delete object._id
      else
        id = Meteor.uuid()
      @_tx._addOperation
        op: 'insertObject'
        collection: @_name
        crdtId: id
        args:
          object: object
      id

    @removeOne = (id) ->
      @_tx._addOperation
        op: 'removeObject'
        collection: @_name
        crdtId: id
      id

    @setProperty = (id, key, value) ->
      @_tx._addOperation
        op: 'insertProperty'
        collection: @_name
        crdtId: id
        args:
          key: key
          value: value
      id

    @unsetProperty = (id, key, locator = null) ->
      args = key: key
      if locator? then args.locator = locator
      @_tx._addOperation
        op: 'removeProperty'
        collection: @_name
        crdtId: id
        args: args
      id

    # The server may reset the collections.
    if Meteor.isServer
      @reset = ->
        @_remove {}
        @_crdts.remove {}
        true

    #######################
    # Transaction Support #
    #######################
    @_getCrdt = (crdtId) ->
      serializedCrdt = @_crdts.findOne _crdtId: crdtId
      if serializedCrdt?
        new Meteor._CrdtDocument @_propSpec, serializedCrdt
      else
        undefined

    # Allocate transaction-specific indexes per CRDT and
    # property.
    @_propertyIdxs = {}
    @_getCurrentIndex = (crdt, key) ->
      @_propertyIdxs[crdt.id] = {} unless @_propertyIdxs[crdt.id]?
      unless @_propertyIdxs[crdt.id][key]?
        @_propertyIdxs[crdt.id][key] = crdt.getNextIndex key
      @_propertyIdxs[crdt.id][key]


    @_updatedCrdts = undefined

    @_txRunning = -> @_updatedCrdts?

    @_txStart = ->
      console.assert not @_txRunning(),
        'Trying to start an already running transaction.'
      @_updatedCrdts = []

      # Make sure that we allocate new property indexes
      # for this transaction.
      @_propertyIdxs = {}
      true

    @_txCommit = ->
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

    @_txAbort = ->
      @_updatedCrdts = undefined


    ##############
    # Operations #
    ##############
    # Add an object to the collection.
    # args:
    #   object: the key/value pairs to create
    @_ops =
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
          @_crdts.update {_crdtId: crdtId},
            {$set: {_deleted: false, _clock: clock}}
          mongoId = crdt.id
        else
          # Create a new CRDT.
          crdt = new Meteor._CrdtDocument @_propSpec
          crdt.crdtId = crdtId
          crdt.clock = clock
          for key, value of args.object
            index = @_getCurrentIndex(crdt, key)
            if _.isArray value
              for entry in value
                crdt.insertAtIndex key, entry, index, site
            else
              crdt.insertAtIndex key, value, index, site
          mongoId = @_crdts.insert crdt.serialize()

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
        @_crdts.update {_crdtId: crdtId},
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
        @_crdts.update {_crdtId: crdtId}, {$set: changedProps}

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
        @_crdts.update {_crdtId: crdtId}, {$set: changedProps}

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
            @_crdts.update {_crdtId: crdtId},
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
            @_crdts.update {_crdtId: crdtId}, {$set: changedProps}

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
            @_crdts.update {_crdtId: crdtId}, {$set: changedProps}

            # Remember the changed CRDT for txCommit.
            @_updatedCrdts.push crdt.id
            undeletedIndices

          else
            # We cannot invert the given operation.
            Meteor.log.throw 'crdt.cannotInvert', op: origOp


if Meteor.isServer
  # Patch the live subscription to automatically publish the CRDT version
  # together with the snapshot version.
  OriginalLivedataSubscription = Meteor._LivedataSubscription
  class Meteor._LivedataSubscription extends OriginalLivedataSubscription
    _synchronizeCrdt: (collection_name, id, attributes) ->
      # If the collection is versioned then publish not only
      # the snapshot value but also its crresponding crdt.
      coll = Meteor.tx._getCollection(collection_name)
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
      changedKeys = _.keys attributes
      # 3) Keys that have been published previously.
      # NB: We never remove previously published CRDT keys from the
      # client, otherwise local undo simulation does not work. This
      # is part of our insert-only CRDT policy.
      oldCrdt = (@snapshot[coll._crdts._name]?[currentCrdt._id]) ? {}
      publishedKeys = _.keys oldCrdt
      crdtKeys = _.union internalKeys, changedKeys, publishedKeys
      crdtAtts = {}
      for crdtKey in crdtKeys
        unless _.isEqual(currentCrdt[crdtKey], oldCrdt[crdtKey])
          crdtAtts[crdtKey] = currentCrdt[crdtKey]
      console.log crdtAtts
      [coll._crdts._name, currentCrdt._id, crdtAtts]

    set: (collection_name, id, attributes, syncCrdt = true) ->
      if syncCrdt
        crdtSet = @_synchronizeCrdt(collection_name, id, attributes)
        if _.isArray(crdtSet)
          [crdtColl, crdtId, crdtAtts] = crdtSet
          super crdtColl, crdtId, crdtAtts
      super collection_name, id, attributes

    unset: (collection_name, id, attributes) ->
      crdtSet = @_synchronizeCrdt(collection_name, id, attributes)
      if _.isArray(crdtSet)
        [crdtColl, crdtId, crdtAtts] = crdtSet
        @set crdtColl, crdtId, crdtAtts, false
      super collection_name, id, attributes

