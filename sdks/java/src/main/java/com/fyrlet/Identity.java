package com.fyrlet;

/** The project and user a client is bound to after its first authenticated identity request. */
record Identity(String projectId, String subjectId) {
}
