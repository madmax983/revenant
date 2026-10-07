// A new org makes the user's personal file library on the first file insert.
// Parallel Apex tests that insert files at the same time can then fail with
// INVALID_CROSS_REFERENCE_KEY. This insert makes the library before the tests.
ContentVersion file = new ContentVersion(
  Title = 'revenant-ci-warm-up',
  PathOnClient = 'revenant-ci-warm-up.txt',
  VersionData = Blob.valueOf('warm-up')
);
insert file;
Id documentId = [
  SELECT ContentDocumentId
  FROM ContentVersion
  WHERE Id = :file.Id
].ContentDocumentId;
delete new ContentDocument(Id = documentId);
