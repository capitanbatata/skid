-- | State of a node, plus operations on this state. The state of a node
--  includes the in-memory key-value map, as well as information about its
--  peers.

module Database.SKID.Node.State
    (  -- * State
      State
    , mkState
      -- * Operations on the state's peers
    , getPeers
    , addPeer
    , removePeer
      -- * Operations on the state's key-value pairs
    , PutType (Local, Remote)
    , Key
    , Value
    , get
    , put
    , mergeKVs
    , localMap
      -- * Operations on the queue of to-send key-value pairs
    , getNextKV
      -- * Operations on the bootstrapped state.
    , isBootstrapped
    , markBootrsapped
    )
where

import           Control.Concurrent.STM        (atomically)
import           Control.Concurrent.STM.TQueue (TQueue, newTQueueIO, readTQueue,
                                                writeTQueue)
import           Control.Concurrent.STM.TVar   (TVar, modifyTVar', newTVarIO,
                                                readTVarIO, writeTVar)
import           Control.Distributed.Process   (ProcessId)
import           Control.Monad                 (when)
import           Control.Monad.IO.Class        (MonadIO, liftIO)
import           Data.ByteString               (ByteString)
import           Data.Map.Strict               (Map)
import qualified Data.Map.Strict               as Map
import           Data.Set                      (Set)
import qualified Data.Set                      as Set

-- | State of a node.
data State = State
    { -- | Set of peers known so far.
      peers :: TVar (Set ProcessId)
      -- | In memory key-value store for the node.
    , kvMap :: TVar (Map Key Value)
      -- | Queue of key-values that have to be set to the peers.
    , sendQ :: TQueue (Key, Value)
      -- | Is the node initialized?
    , initT :: TVar Bool
    }

type Key = ByteString
type Value = ByteString

mkState :: IO State
mkState = State <$> newTVarIO Set.empty
                <*> newTVarIO Map.empty
                <*> newTQueueIO
                <*> newTVarIO False

-- | Get set of the peers known so far.
getPeers :: MonadIO m => State -> m (Set ProcessId)
getPeers st = liftIO $
    readTVarIO (peers st)

-- | Add a peer to the set of known peers.
addPeer :: MonadIO m => State -> ProcessId -> m ()
addPeer st pId = liftIO $ atomically $
    modifyTVar' (peers st) (pId `Set.insert`)

-- | Remove a peer from the set of known peers.
removePeer :: MonadIO m => State -> ProcessId -> m ()
removePeer st pId = liftIO $ atomically $
    modifyTVar' (peers st) (pId `Set.delete`)

-- | Get the given key.
get :: MonadIO m => State -> Key -> m (Maybe Value)
get st k = fmap (Map.lookup k) $ liftIO $ readTVarIO (kvMap st)

-- | Put the given key with the given value to the state.
--
--
-- The put-type must be @Local@ when the key-value pair was added in the local
-- node, and therefore has to be communicated to its peers. If the put type is
-- @Remote@, this means that the key-value pair was received from another peer,
-- and therefore the other nodes __should not__ be notified.
--
put :: MonadIO m => State -> PutType -> Key -> Value -> m ()
put st pt k v = liftIO $ atomically $ do
    modifyTVar' (kvMap st) (Map.insert k v)
    when (pt == Local) $ writeTQueue (sendQ st) (k, v)

-- | Type of the put operation. This is needed to decide whether the newly
-- added key-value pair has to be communicated to peers.
data PutType = Local | Remote deriving (Eq)

-- | Get the next key-value pair from the queue of data to be sent to the
-- peers.
getNextKV :: MonadIO m => State -> m (Key, Value)
getNextKV st = liftIO $ atomically $
    readTQueue (sendQ st)

-- | Is the node bootstraped?
--
-- A node is considered to be bootstrapped if either no peers are found after a
-- certain period of time, or the global key-value map was received from one of
-- the peers.
isBootstrapped :: MonadIO m => State -> m Bool
isBootstrapped st = liftIO $
    readTVarIO (initT st)

-- | Mark the node as bootstrapped.
markBootrsapped :: MonadIO m => State -> m ()
markBootrsapped st = liftIO $ atomically $
    writeTVar (initT st) True

-- | Merge the given key-value pairs with the local ones. The key-value pairs
-- will overwrite the local versions.
mergeKVs :: MonadIO m => State -> Map Key Value -> m ()
mergeKVs st mm = liftIO $ atomically $
    modifyTVar' (kvMap st) (Map.union mm)

-- | Return the internal key-value map.
localMap :: MonadIO m => State -> m (Map Key Value)
localMap st = liftIO $
    readTVarIO (kvMap st)
