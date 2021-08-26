{ lib
, buildPythonPackage
, fetchPypi
, codecov
, pyjwt
, pylint
, pytestCheckHook
, pytest-cov
, python-dateutil
, requests
, responses
, tox
}:

buildPythonPackage rec {
  pname = "ibm-cloud-sdk-core";
  version = "3.11.3";

  src = fetchPypi {
    inherit pname version;
    sha256 = "c855d0111dd570f36497cdb8c11510ae8d14fb70698f20529e19f88485266233";
  };

  checkInputs = [
    codecov
    pylint
    pytestCheckHook
    pytest-cov
    responses
    tox
  ];

  propagatedBuildInputs = [
    pyjwt
    python-dateutil
    requests
  ];

  # Various tests try to access credential files which are not included with the source distribution
  disabledTests = [
    "test_configure_service"
    "test_cp4d_authenticator"
    "test_cwd"
    "test_files_dict"
    "test_files_duplicate_parts"
    "test_files_list"
    "test_get_authenticator"
    "test_gzip_compression_external"
    "test_iam"
    "test_read_external_sources_2"
    "test_retry_config_external"
  ];

  meta = with lib; {
    description = "Client library for the IBM Cloud services";
    homepage = "https://github.com/IBM/python-sdk-core";
    license = licenses.asl20;
    maintainers = with maintainers; [ globin lheckemann ];
  };
}
