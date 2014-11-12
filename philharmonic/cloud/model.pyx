# encoding: utf-8
# cython: profile=True

'''
The cloud model as seen from the cloud provider's perspective.

Created on Jul 11, 2013

@author: kermit

'''

import copy
import itertools

from philharmonic.utils import deprecated, CommonEqualityMixin
from . import visualiser

def format_spec(spec):
    s = "{"
    separator = " "
    for key, value in spec.iteritems():
        s += "{0}:{1}{2}".format(key, value, separator)
    s = s[:-len(separator)]
    s += "}"
    return s

class ModelUsageError(Exception):
    pass

# some non-semantic functionality common for VMs and servers
class Machine(object):
    resource_types = ['RAM', '#CPUs'] # can be overridden
    _weights = None

    def __init__(self, *args):
        self.id = type(self)._new_id()
        self.spec = {}
        for (i, arg) in enumerate(args):
            self.spec[self.resource_types[i]] = arg

    def __str__(self):
        return self.__repr__()

    def full_info(self, location=True):
        if location:
            return "{0}:{1}".format(repr(self),
                                    format_spec(self.spec))
        else:
            return "{2}:{0}:{1}".format(self.id,
                                        format_spec(self.spec),
                                        self.machine_type)

    def __repr__(self):
        return "{}:{}".format(self.machine_type, str(self.id))

    def __eq__(self, other):
        try:
            eq = (self.id, self.machine_type) == (other.id, other.machine_type)
        except AttributeError:
            eq = id(self) == id(other)
        return eq

    def __hash__(self):
        try:
            return hash((self.id, self.machine_type))
        except AttributeError:
            return hash(id(self))

    class __metaclass__(type):
        @property
        def weights(cls):
            """weights class property - only calculate on the 1st call
            from cls.resource_types

            """
            if cls._weights is None:
                uniform_weight = 1./len(cls.resource_types)
                cls._weights = {r : uniform_weight for r in cls.resource_types}
            return cls._weights


def _delegate_to_obj(obj, method_name, *args):
    method = getattr(obj, method_name)
    method(*args)


# the model
# ==========

class VM(Machine):

    machine_type = 'VM'
    _new_id = itertools.count(start=1).next

    def __init__(self, *args):
        super(VM, self).__init__(*args)
        self.res = self.spec

    # calling (un)pause or migrate on a VM gets routed to the cloud
    # and then to the current state

    #TODO: create these methods automatically
    def pause(self):
        _delegate_to_obj(self.cloud, self.pause.__name__, self)

    def unpause(self):
        _delegate_to_obj(self.cloud, self.unpause.__name__, self)

    def migrate(self, server):
        _delegate_to_obj(self.cloud, self.pause.__name__, self, server)

class Server(Machine):
    """A physical server."""

    machine_type = 'PM'
    _new_id = itertools.count(start=1).next

    def __init__(self, *args, **kwargs):
        """@param location: server's geographical location"""
        super(Server, self).__init__(*args)
        self.cap = self.spec
        if 'location' in kwargs:
            self._loc = kwargs['location']

    def get_location(self):
        return self._loc

    def set_location(self, location):
        self._loc = location

    location = property(get_location, set_location, doc="geographical location")
    loc = property(get_location, set_location, doc="geographical location")

    def __repr__(self):
        try:
            s = "{}:{}".format(self.machine_type, str(self.id))
        except AttributeError: # bug I noticed on some old pickled data
            s = "{}:{}".format(self.machine_type, id(self))
        try:
            s += '@{}'.format(self.location)
        except AttributeError:
            pass
        return s

# Schedule
# ==========

class State(object):
    """the state of the cloud at a single moment. Various methods like migrate,
    pause... for changing it."""

    @staticmethod
    def random():
        """create a random state"""
        #TODO: randomize
        return State([Server(2,2), Server(4,4)], [VM(1,1), VM(1,1)])

    def __init__(self, servers=[], vms=set(), auto_allocate=False):
        self.servers = servers
        self.vms = vms
        self._alloc = {} # servers -> allocated machines
        # servers -> remaining free capacity
        self.free_cap = {s : copy.copy(s.cap) for s in servers}
        self.paused = set() # those VMs that are paused
        self.suspended = set() # those VMs that are paused
        for s in self.servers:
            self._alloc[s] = set()
        if auto_allocate:
            self.auto_allocate()

    def __repr__(self):
        rep = ''
        for s in self.servers:
            s_rep = '%s -> %s;\n' % (s.__repr__(), self._alloc[s].__repr__())
            rep += s_rep
        return rep

    @property
    def alloc(self):
        """dict giving for every server the set of VMs allocated to it"""
        # TODO: return copy where setting items raises error
        # - make dictionary read only
        return self._alloc

    def _copy_alloc(self, other_alloc):
        """copy other_alloc to your own alloc"""
        self._alloc = {}
        for s, vms in other_alloc.iteritems():
            self.alloc[s] = set(vms) # create a new set

    def auto_allocate(self):
        """place all VMs on the first server"""
        for vm in self.vms:
            self.place(vm, self.servers[0])
        return self


    def place(self, vm, s):
        """change current state to have vm on server s"""
        if vm not in self._alloc[s]:
            self._alloc[s].add(vm)
            for r in s.resource_types: # update free capacity
                self.free_cap[s][r] -= vm.res[r]
        return self

    def remove(self, vm, s):
        """change current state to not have vm on server s"""
        if vm in self._alloc[s]:
            self._alloc[s].remove(vm)
            for r in s.resource_types: # update free capacity
                self.free_cap[s][r] += vm.res[r]
        return self

    def remove_all(self, s):
        """change current state to have no VMs on server s"""
        self._alloc[s] = set()
        self.free_cap[s] = copy.copy(s.cap)
        return self

    # action effects (consequence of applying Action to State)
    #---------------

    def migrate(self, vm, s):
        """change current state to have vm in s instead of the old location"""
        if vm not in self.vms:
            raise ModelUsageError("attempt to migrate VM that isn't booted")
        for server, vms in self._alloc.iteritems():
            if vm in vms:
                if server == s:
                    # it's already there
                    return
                else: # VM was elsewhere - removing
                    # remove from old server
                    self.remove(vm, server)
        # add it to the new one
        if s is not None: # if s is None, vm is being deleted
            self.place(vm, s)
        # TODO: faster reverse-dictionary lookup
        # http://stackoverflow.com/a/2569076/544059
        return self

    def pause(self, vm):
        self.paused.add(vm) # add to paused set
        return self

    def unpause(self, vm):
        try:
            self.paused.remove(vm) # remove from paused set
        except KeyError:
            pass
        return self

    def boot(self, vm):
        """a VM is requested by the user, but is not yet allocated"""
        self.vms.add(vm)
        return self

    def delete(self, vm):
        """user requested for a vm to be deleted"""
        self.migrate(vm, None) # remove vm from its host server
        try: #  remove the vm from this state's active vms
            self.vms.remove(vm)
        except KeyError: # the VM wasn't even there (booted outside environment)
            pass
        return self

    #---------------

    def copy(self):
        """ return a copy of the state with a new alloc instance"""
        new_state = State()
        #new_state.__dict__.update(self.__dict__)
        new_state.servers = self.servers
        new_state.vms = copy.copy(self.vms)
        new_state._copy_alloc(self._alloc)
        new_state.free_cap = {}
        for s in self.servers:
            # copy the free_cap dictionary
            try:
                new_state.free_cap[s] = copy.copy(self.free_cap[s])
            except AttributeError: # temp fix due to supporting old servers.pkl
                self.free_cap = {s : copy.copy(s.cap) for s in self.servers}
                new_state.free_cap[s] = copy.copy(self.free_cap[s])
        #TODO: copy.copy - probably faster
        return new_state

    # creates a new VMs list
    def transition(self, action):
        """transition into new state acccording to action"""
        new_state = self.copy()
        #new_state.migrate(migration.vm, migration.server)
        apply_effect = getattr(new_state, action.name)
        apply_effect(*action.args)
        return new_state

    def utilisation(self, s, weights=None):
        """utilisation ratio of a server s"""
        if weights is None:
            weights = Machine.weights
        total_utilisation = 0.
        for r in s.resource_types:
            used = s.cap[r] - self.free_cap[s][r]
            utilisation = used / float(s.cap[r])
            if utilisation > 1:
                utilisation = 1
            total_utilisation += weights[r] * utilisation
        return total_utilisation

    def calculate_utilisations(self):
        """return dict server -> utilisation rate"""
        self.utilisations = {}
        for server in self.servers:
            total_utilisation = self.utilisation(server)
            self.utilisations[server] = total_utilisation
        return self.utilisations

    # constraint checking
    # C1
    def is_allocated(self, vm):
        """True if @param vm is allocated to any server in this state."""
        for s in self.servers:
            if vm in self._alloc[s]:
                return True
        return False

    def allocation(self, vm):
        """The server to which @param vm is allocated or None."""
        for s in self.servers:
            if vm in self._alloc[s]:
                return s
        return None

    def unallocated_vms(self):
        """Return the set of unallocated VMs."""
        unallocated = set(copy.copy(self.vms))
        for s in self.servers:
            unallocated = unallocated.difference(self._alloc[s])
        return unallocated

    def all_allocated(self):
        """True if all currently requested VMs are allocated."""
        return len(self.unallocated_vms()) == 0

    def ratio_allocated(self):
        """The ratio of allocated VMs compared to all the requested VMs."""
        to_check = set(copy.copy(self.vms))
        total = len(to_check)
        if total == 0:
            return 1.0
        for s in self.servers:
            to_check = to_check.difference(self._alloc[s])
        allocated = total - len(to_check)
        ratio = float(allocated) / total
        return ratio

    #C2
    def within_capacity(self, s):
        """Server s within capacity? Check resources occupied by the allocated
        VMs and check if it exceeds the available resource capacity.

        """
        if s is None:
            pass
        for i in s.resource_types:
            if self.free_cap[s][i] < 0:
                return False
        return True

    def overcapacitated_servers(self):
        """Return the set of servers that are not within capacity."""
        servers = set(self.servers)
        overcap = servers.difference(
            set([s for s in servers if self.within_capacity(s)])
        )
        return overcap

    def all_within_capacity(self):
        """Are all the servers within capacity?"""
        for s in self.servers:
            if not self.within_capacity(s):
                return False
        return True

    def capacity_penalty(self):
        """Return a penalty 0-1.0, indicating by how much the capacity
        of all the servers has been exceeded (closer to 1. means more servers
        are overcapacitated).

        """
        max_overcap = {res: 0. for res in Machine.resource_types}
        ratio_overcap = {res: 0. for res in Machine.resource_types}
        for s in self.servers:
            for r in Machine.resource_types:
                overcap = -1 * self.free_cap[s][r]
                if overcap > max_overcap[r]:
                    max_overcap[r] = overcap
                    ratio_overcap[r] = float(overcap) / s.cap[r]
        penalty = pd.Series(ratio_overcap).mean()
        if penalty > 1.:
            penalty = 1.
        return penalty

    def ratio_within_capacity(self): # TODO: by resource overflows
        """Ratio of servers that are within capacity."""
        num_ok = 0
        for s in self.servers:
            if self.within_capacity(s):
                num_ok += 1
        if len(self.servers) == 0:
            return 1.0
        ratio = float(num_ok) / len(self.servers)
        return ratio

    def server_free(self, s):
        """True if there are no VMs allocated to server @param s."""
        return len(self._alloc[s]) == 0

    def underutilised(self, s, threshold = 0.25):
        """If the server is non-empty and utilisation below threshold."""
        return not self.server_free(s) and self.utilisation(s) < threshold

# The ranking determines which the order in which to apply the actions,
# given the same timestamps.
actions = ['boot', 'delete', 'migrate', 'pause', 'unpause']
action_rank = dict(zip(actions, range(len(actions))))

class Action(CommonEqualityMixin):
    """A static representation of an action on the cloud."""
    name = ''
    args = None
    def __repr__(self):
        return '{0}: {1}'.format(self.name, str(self.args))
    def __str__(self):
        return self.__repr__()

    def rank(self):
        """the action's rank - used for sorting"""
        return action_rank[self.name]

class Migration(Action):
    """migrate vm to server"""
    def __init__(self, vm, server):
        self.vm = vm
        self.server = server
        self.args = [vm, server]
    name = 'migrate'
    def __repr__(self):
        return '{} -> {}'.format(str(self.vm), str(self.server))

class Pause(Action):
    """pause vm"""
    def __init__(self, vm):
        self.args = [vm]
    name = 'pause'

class Unpause(Action):
    """pause vm"""
    def __init__(self, vm):
        self.args = [vm]
    name = 'unpause'

class VMRequest(Action):
    """VM creation/deletion actions. Applying a boot action adds it to
    cloud.vms, but it does not place it to a concrete server. A delete
    action also unallocates the VM and frees the server's resources.

    """
    def __init__(self, vm, what):
        self.vm = vm
        self.args = [vm]
        self.what = what
        self.name = self.what
    def __str__(self):
        return "{0} {1}".format(self.what, self.vm)
    def __repr__(self):
        return self.__str__()

import pandas as pd
class Schedule(object):
    """(initial state? - part of Cloud) and a time series of actions"""
    def __init__(self):
        self.actions = pd.TimeSeries()
        self.actions.name = 'actions'

    def sort(self):
        # - actions in the current time have to be sorted by Action.rank()
        # - sort_index has to be stable - not sure if it is
        # self.actions = self.actions.sort_index()
        # maybe cache ranked_actions, don't create it from scratch every time
        ranked_actions = pd.DataFrame({'actions': self.actions,
                                       'rank': [a.rank() for a in self.actions],
                                       'index': self.actions.index},
                                      index=self.actions.index)
        self.actions = ranked_actions.sort(['index', 'rank']).actions
        self.actions.name = 'actions'

    def clean(self):
        """Remove duplicates and only consider the last action on a VM if
        multiple exist for the same timestamp.

        """
        # TODO: is a check to leave boots alone necessary?
        self.actions.drop_duplicates(inplace=True)

    def add(self, action, t):
        """Add an action to the schedule. Make sure it's still sorted.
        Return True/False to indicate success."""
        try:
            existing_actions = self.filter_current_actions(
                t, self.environment.period)
        except AttributeError: # if no environment available
            pass # TODO: maybe raise after all - confusing
        else:
            for t_ex, existing in existing_actions.iteritems():
                if existing == action:
                    # we don't add anything as there already exists the same
                    # action at time t
                    return False
                if existing.name == action.name and existing.vm == action.vm:
                    # only if there was another action of the same name
                    # (e.g. migrate) for this VM, do we
                    # remove the old one, as the new one supersedes it
                    self.actions = self.actions[self.actions != existing]
        new_action = pd.Series({t: action})
        self.actions = pd.concat([self.actions, new_action])
        #TODO: optimise this to only sort the new actions
        self.sort()
        return True

    def filter_current_actions(self, t, period=None):
        """return time series of actions in interval
        (closed on the left, open on the right)

        """
        if period is None:
            return self.actions.ix[t:]
        justabit = pd.offsets.Micro(1)
        return self.actions.ix[t:t + period - justabit]
        #return self.actions[t:t + period - justabit]

    def __repr__(self):
        return self.actions.__repr__()

    def __str__(self):
        return self.actions.__str__()

# Cloud
# ==========

class Cloud():
    """Contains all the VMs and servers and keeps current/future/past states.
    Does not perform real actions by itself, but serves as a placeholder
    for experimenting with and evaluating actions by the Scheduler.

    The IManager can then use the real state and the Schedule to
    perform actual actions.

    States:
    - _initial - at the very beginning (probably no VMs allocated)
    - _real - reflects the actual physical allocations
              (as of the last action applied by the manager)
    - _current - _real or some later virtual state - controlled by the Scheduler

    Note: _current must not be assigned to _real, but always on its copy, so as
    not to change anything in _real!

    Workflow:
    - action on Cloud -> create Action instance -> add to Schedule

    """
    def __init__(self, servers=[], initial_vms=set(), auto_allocate=False):
        self._servers = servers
        self._initial = State(servers, set(initial_vms), auto_allocate)
        for machine in servers + list(initial_vms): # know thy parent
            machine.cloud = self
        self._real = self._initial.copy()
        self.reset_to_real()

    # a couple of debugging methods ---
    def show(self):
        print(self.get_current())

    def show_usage(self):
        """log detailed cloud description"""
        # TODO: have this method return the string (for easier debugging)
        visualiser.show_usage(self, self.get_current())
    #----------------------------------

    #TODO: this seems wrong - current should always be a copy?
    def reset_to_real(self):
        """Set the current state back to what the real state of the cloud is."""
        self._current = self._real.copy()

    def reset_to_initial(self):
        """Set the current state back to the initial state."""
        self._current = self._initial.copy()

    def get_vms(self):
        """return the VMs in the current state"""
        return self._current.vms

    def get_servers(self):
        return self._servers

    def get_current(self):
        """Get the current state."""
        return self._current

    vms = property(get_vms, doc="get the VMs in the current state")
    servers = property(get_servers, doc="get the servers (always the same)")

    def apply(self, action):
        """Apply an Action on the current state."""
        self._current = self._current.transition(action)
        return self._current

    def apply_real(self, action):
        """Apply an Action on the real state (reflecting the actual physical
        state) and reset the virtual state.

        """
        self._real = self._real.transition(action)
        self.reset_to_real()
        return self._real

    @deprecated
    def connect(self):
        """Establish a connection with the driver
        Deprecated - the manager should apply actions, not the Cloud model."""
        self.driver.connect()

    #TODO: do we really want methods here as well? Action instances better?
    def pause(self, *args):
        _delegate_to_obj(self._current, self.pause.__name__, *args)

    def unpause(self, *args):
        _delegate_to_obj(self._current, self.unpause.__name__, *args)

#TODO: separate model for planning actions (state, transition etc.)
# and model for really executing actions

#TODO: maybe split into several files
# - model
# - schedule
# (- cloud)