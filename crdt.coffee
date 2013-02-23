# A commutative replicative data type.
class Meteor._CrdtDocument
  constructor: (@collProps = null, serializedCrdt = null) ->
    if serializedCrdt?
      {
        _id: @id
        _crdtId: @crdtId
        _clock: @clock
        _deleted: @deleted
      } = serializedCrdt
      @properties = _.omit serializedCrdt,
        '_id', '_crdtId', '_clock', '_deleted'
    else
      @id = undefined
      @crdtId = undefined
      @clock = {}
      @properties = {}
      @deleted = false

  getNextIndex: (key) ->
    if @properties[key]? then @properties[key].length else 0

  getOrderedVisiblePayloads: (key) ->
    return [] unless @properties[key]
    payloads = []
    for sites, index in @properties[key]
      for site, changes of sites
        for payload, change in changes
          _.extend payload,
            index: index
            site: site
            change: change
      sortedSites = _.sortBy sites, (payload) -> payload.site
      for changes in sortedSites
        for payload in changes
          payloads.push payload unless payload.deleted
    payloads

  # Inserts the payload into the property list.
  #
  # Order:
  # - for causally related operations: The ordering is
  #   automatically causal as transactions preserve causality.
  #   Causal order is represented by the index value.
  # - for concurrent transactions: We order lexicographically
  #   by originating site to ensure a globally unique order.
  # - for changes within a transaction: Order is the same
  #   as the order of operations in the transaction.
  #
  # This ordering has the following properties:
  # - Causality is preserved (index).
  # - We get a unique order for concurrent transactions,
  #   independently of the order in which they arrive (site).
  # - Effects caused by the same transaction will be
  #   kept in a single run so that effects from several
  #   concurrent transactions do not interleave (change).
  #
  # Assume we have the following events:
  # tx | clock vector     | site  | appended values
  # ==================================================
  # 1  | [Alice 1, Bob 0] | Alice | index 0, [a, b, c]
  # 2  | [Alice 2, Bob 0] | Alice | index 1, [f, g]
  # 3  | [Alice 0, Bob 1] | Bob   | index 0, [d, e]
  #
  # This establishes the following causality:
  # - Transaction 2 happend-after transaction 1.
  # - Transaction 3 happened concurrently with transactions 1 and 2
  #
  # Now assume that the transactions arrive in the order 3, 2, 1:
  # When tx 3 arrives, the local clock is [Alice 0, Bob 0]. This
  # means that tx 3 will be executed immediately:
  #
  # properties:
  #   0:           -- index
  #     Bob:       -- site
  #       d, e     -- changes
  #
  # When tx 2 arrives, the local clock is [Alice 0, Bob 1]. This
  # means that the transaction will be recognized as out-of-order
  # and staged as a pending transaction.
  #
  # When tx 1 arrives, the local clock still is [Alice 0, Bob 1].
  # Tx 1 is recognized as concurrent transaction and will be
  # executed:
  #
  # properties:
  #   0:           -- index
  #     Alice:     -- site (ordered lexicographically)
  #       a, b, c  -- changes
  #     Bob:
  #       d, e
  #
  # The clock advanced to [Alice 1, Bob 1]. Now the previously
  # arrived tx 3 is no longer pending and can be executed:
  #
  # properties:
  #   0:
  #     Alice:
  #       a, b, c
  #     Bob:
  #       d, e
  #   1:
  #     Alice:
  #       f, g
  #
  # So the final order of all operations will be:
  #   a, b, c, d, e, f, g
  # All participating sites will converge to this unique
  # order independently of the order in which transactions
  # arrive. This preserves causality and intention.
  #
  # NB: We currently only allow appending of new values as this
  #     is all we need to resolve conflicts for JS objects.
  #     If we want to insert to the middle of the collection
  #     (e.g. to resolve conflicts for a text document) then
  #     we need a more sophisticated index, see the binary tree
  #     index implementation I had in the early versions of this
  #     class (https://gist.github.com/jerico-dev/4566560).
  insertAtIndex: (key, value, index, site) ->
    # Create a new entry.
    payload =
      deleted: false
      value: value

    # Append the property to the crdt's property list.
    @properties[key] = [] unless @properties[key]?
    property = @properties[key]

    # Check that the index is valid.
    unless index == 0 or property[index-1]?
      Meteor.log.throw 'crdt.tryingToInsertIndexOutOfOrder',
        {key: key, index: index, site: site}
    property[index] = {} unless property[index]?
    property[index][site] = [] unless property[index][site]?
    property[index][site].push payload

    # Return the index of the new property.
    [index, site, property[index][site].length - 1]

  # Mark (entries for) the specified property deleted (invisible).
  #
  # locator:
  # - for Arrays: If an (integer) locator N is given, then
  #   only the N'th currently visible entry will be marked
  #   deleted.
  # - for Subdocs: If a (string) locator key:value is given, then
  #   all entries where the subkey 'key' equals 'value' of the
  #   object will be marked deleted.
  # - for Scalars: No locator can be given and all currently
  #   visible entries will be deleted.
  # In all cases: If no locator was given then all property
  # entries for that property will be marked deleted.
  delete: (key, locator = null) ->
    return [] unless @properties[key]?

    # Find all visible payloads for this key.
    payloads = @getOrderedVisiblePayloads(key)

    # In the case of named subdocuments: filter by locator
    # if a locator has been given.
    if locator? and @collProps[key]?.type == '[{}]' # Named subdocuments.
      payloads = _.filter payloads, (payload) =>
        payload.value[@collProps[key].locator] == locator

    # Delete the specified entry or entries.
    if locator? and @collProps[key]?.type == '[*]' # A single array index.
      unless 0 <= locator < payloads.length
        Meteor.log.throw 'crdt.tryingToDeleteNonexistentKeyAtPos',
          {key:key, pos: locator, crdtId: @crdtId}
      delPl = payloads[locator]
      delPl.deleted = true
      # Return the index of the deleted entry as an array.
      [[delPl.index, delPl.site, delPl.change]]
    else # Scalar, (full) Array or Subdocuments
      if payloads.length == 0
        # This may happen when we have two concurrent delete operations
        # on exactly the same key. As this is not probable we log
        # a warning which may help to identify errors.
        Meteor.log.warning 'crdt.tryingToDeleteNonexistentKey',
          {key:key, crdtId: @crdtId}
      # Return the comprehension with the indices of all deleted entries.
      for delPl in payloads
        delPl.deleted = true
        [delPl.index, delPl.site, delPl.change]

  _setDeleted: (key, index, site, change, deleted) ->
    unless @properties[key]?[index]?[site]?[change]?
      Meteor.log.throw 'crdt.tryingToUnDeleteNonexistentIndex',
        {key: key, index: index, site: site, change: change}
    payload = @properties[key][index][site][change]
    if payload.deleted == deleted
      # This may happen when two sites delete exactly the
      # same index concurrently. As this is not probable we
      # provide a warning as this may point to an error.
      Meteor.log.warning 'crdt.tryingToUnDeleteIndexInVisibleEntry',
        {key: key, index: index, site: site, change: change}
    payload.deleted = deleted
    [index, site, change]

  # Mark the property at the given index deleted (invisible). The
  # second argument is redundant and just for consistency checking.
  deleteIndex: (key, index, site, change) ->
    @_setDeleted key, index, site, change, true

  # Mark the property at the given index not deleted (visible).
  undeleteIndex: (key, index, site) ->
    @_setDeleted key, index, site, change, false

  serialize: ->
    serializedCrdt = @properties
    _.extend serializedCrdt,
      _id: @id
      _crdtId: @crdtId
      _clock: @clock
      _deleted: @deleted
    serializedCrdt

  snapshot: ->
    if @deleted
      null
    else
      # Including the clock in the snapshot is not only
      # informative but makes sure that we always get
      # notified over DDP when something changed in the
      # CRDT and get a chance to publish those changes.
      snapshot =
        _id: @crdtId
        _clock: @clock
      # Build properties but filter deleted entries.
      for key of @properties
        for payload in @getOrderedVisiblePayloads(key)
          value = payload.value
          switch @collProps[key]?.type
            when '[*]'
              # The value of this property is an array.
              snapshot[key] = [] unless snapshot[key]?
              snapshot[key].push value
            when '[{}]'
              # The value of this property is a collection of
              # subdocs with a unique key. This guarantees
              # that subsequent values with the same subkey
              # will overwrite each other.
              snapshot[key] = {} unless snapshot[key]?
              subkey = value[@collProps[key].locator]
              snapshot[key][subkey] = value
            else
              # The value of this property is a scalar
              # (cardinality 0-1). We let later values
              # overwrite earlier ones.
              snapshot[key] = value
      # Transform lists of subdocuments to arrays.
      for collKey, collSpec of @collProps when collSpec.type = '[{}]'
        snapshot[collKey] = _.values snapshot[collKey]
      snapshot
