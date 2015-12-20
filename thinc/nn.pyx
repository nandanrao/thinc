from __future__ import print_function
cimport cython

from cymem.cymem cimport Pool
from preshed.maps cimport map_init as Map_init
from preshed.maps cimport map_set as Map_set
from preshed.maps cimport map_get as Map_get

from .typedefs cimport weight_t, atom_t, feat_t
from .blas cimport VecVec
from .eg cimport Example, Batch
from .structs cimport ExampleC

import numpy

cdef class NeuralNet:
    def __init__(self, widths, weight_t eta=0.005, weight_t eps=1e-6, weight_t rho=1e-4):
        self.mem = Pool()
        self.c.eta = eta
        self.c.eps = eps
        self.c.rho = rho

        self.c.nr_layer = len(widths)
        self.c.widths = <int*>self.mem.alloc(self.c.nr_layer, sizeof(self.c.widths[0]))
        cdef int i
        for i, width in enumerate(widths):
            self.c.widths[i] = width

        self.c.nr_weight = 0
        for i in range(self.c.nr_layer-1):
            self.c.nr_weight += self.c.widths[i+1] * self.c.widths[i] + self.c.widths[i+1]

        self.c.weights = <weight_t*>self.mem.alloc(self.c.nr_weight, sizeof(self.c.weights[0]))
        self.c.support = <weight_t*>self.mem.alloc(self.c.nr_weight, sizeof(self.c.weights[0]))

        Map_init(self.mem, &self.c.sparse_weights, 8)
        Map_init(self.mem, &self.c.sparse_support, 8)

        cdef weight_t* W = self.c.weights
        for i in range(self.c.nr_layer-2): # Don't init softmax weights
            W = _init_layer_weights(W, self.c.widths[i+1], self.c.widths[i])

    def Example(self, input_, label=None):
        if isinstance(input_, Example):
            return input_
        return Example(nn_shape=self.widths, features=input_, label=label)

    def Batch(self, inputs, costs=None):
        return Batch(self.widths, inputs, costs)
   
    def __call__(self, input_):
        cdef Example eg = self.Example(input_)

        NeuralNet.forward(eg.c.fwd_state,
            self.c.weights, self.c.widths, self.c.nr_layer)
        memcpy(eg.c.scores, eg.c.fwd_state[self.c.nr_layer-1],
               self.nr_out * sizeof(weight_t)) 
        eg.c.guess = arg_max_if_true(eg.c.scores, eg.c.is_valid, eg.c.nr_class)
        eg.c.best = arg_max_if_zero(eg.c.scores, eg.c.costs, eg.c.nr_class)
        return eg

    def train(self, Xs, ys):
        cdef Batch mb = self.Batch(Xs, ys)
        # Compute the gradient for each example in the batch
        cdef ExampleC* eg
        for i in range(mb.c.nr_eg):
            eg = &mb.c.egs[i]
            NeuralNet.forward_backward(eg.gradient, eg.fwd_state, eg.bwd_state,
                eg.costs, &self.c)
        # Now sum the gradients
        for i in range(mb.c.nr_eg):
            VecVec.add_i(mb.c.gradient, mb.c.egs[i].gradient, 1.0, self.c.nr_weight)
        # Apply L2 regularization
        VecVec.add_i(mb.c.gradient,
            self.c.weights, self.c.rho, self.c.nr_weight)
        
        Adagrad.update(self.c.weights, mb.c.gradient, self.c.support,
            self.c.nr_weight, self.c.eta, self.c.eps)

        #for key, upd in sparse_gradient.items():
        #    Adagrad.update(weight, upd, support,
        #        length, self.c.eta, self.c.eps)
        
        # Fix the state of the examples
        for i in range(mb.c.nr_eg):
            eg = &mb.c.egs[i]
            memcpy(eg.scores, eg.fwd_state[self.c.nr_layer-1],
                   self.nr_out * sizeof(weight_t))
            eg.guess = arg_max_if_true(eg.scores, eg.is_valid, eg.nr_class)
            eg.best = arg_max_if_zero(eg.scores, eg.costs, eg.nr_class)
        return mb.loss
    
    property weights:
        def __get__(self):
            return [self.c.weights[i] for i in range(self.c.nr_weight)]
        def __set__(self, weights):
            for i, weight in enumerate(weights):
                self.c.weights[i] = weight
    property support:
        def __get__(self):
            return [self.c.support[i] for i in range(self.nr_weight)]
        def __set__(self, weights):
            for i, weight in enumerate(weights):
                self.c.support[i] = weight

    property widths:
        def __get__(self):
            return tuple(self.c.widths[i] for i in range(self.c.nr_layer))

    property nr_layer:
        def __get__(self):
            return self.c.nr_layer
    property nr_weight:
        def __get__(self):
            return self.c.nr_weight
    property nr_out:
        def __get__(self):
            return self.c.widths[self.c.nr_layer-1]
    property nr_in:
        def __get__(self):
            return self.c.widths[0]

    property eta:
        def __get__(self):
            return self.c.eta
        def __set__(self, eta):
            self.c.eta = eta
    property rho:
        def __get__(self):
            return self.c.rho
        def __set__(self, rho):
            self.c.rho = rho
    property eps:
        def __get__(self):
            return self.c.eps
        def __set__(self, eps):
            self.c.eps = eps


cdef weight_t* _init_layer_weights(weight_t* W, int nr_out, int nr_wide) except NULL:
    cdef int i
    std = numpy.sqrt(2.0) * numpy.sqrt(1.0 / nr_wide)
    values = numpy.random.normal(loc=0.0, scale=std, size=(nr_out * nr_wide))
    for i in range(nr_out * nr_wide):
        W[i] = values[i]
    W += nr_out * nr_wide
    for i in range(nr_out):
        W[i] = 0.2
    return W + nr_out


cdef int arg_max(const weight_t* scores, const int n_classes) nogil:
    cdef int i
    cdef int best = 0
    cdef weight_t mode = scores[0]
    for i in range(1, n_classes):
        if scores[i] > mode:
            mode = scores[i]
            best = i
    return best


cdef int arg_max_if_true(const weight_t* scores, const int* is_valid,
                         const int n_classes) nogil:
    cdef int i
    cdef int best = 0
    cdef weight_t mode = -900000
    for i in range(n_classes):
        if is_valid[i] and scores[i] > mode:
            mode = scores[i]
            best = i
    return best


cdef int arg_max_if_zero(const weight_t* scores, const weight_t* costs,
                         const int n_classes) nogil:
    cdef int i
    cdef int best = 0
    cdef weight_t mode = -900000
    for i in range(n_classes):
        if costs[i] == 0 and scores[i] > mode:
            mode = scores[i]
            best = i
    return best
